-- Podium — migration 003: RPC functions for public session lookup, rating stats, and leaderboard
-- These functions use security definer so the audience can read safe aggregates and lookup sessions
-- without having direct table SELECT permissions.

-- ---------------------------------------------------------------- RATE LIMITING
create or replace function public.check_code_lookup_rate_limit(client_key text)
returns boolean
language plpgsql
security definer
as $$
declare
  lim record;
begin
  select count, reset_at into lim
  from public.rate_limits
  where key = client_key;

  if not found or lim.reset_at < now() then
    insert into public.rate_limits (key, count, reset_at)
    values (client_key, 1, now() + interval '1 minute')
    on conflict (key) do update
    set count = 1, reset_at = now() + interval '1 minute';
    return true;
  end if;

  if lim.count >= 20 then
    return false;
  end if;

  update public.rate_limits
  set count = count + 1
  where key = client_key;

  return true;
end;
$$;

-- ---------------------------------------------------------------- GET_SESSION_PUBLIC
-- Audience / screen safe lookup. Returns only public metadata and current presentation.
-- Same empty response for invalid codes or rate-limited requests to prevent enumeration.

create or replace function public.get_session_public(lookup_code text)
returns jsonb
language plpgsql
security definer
as $$
declare
  norm_code text;
  client_ip text;
  rate_ok   boolean;
  sess      record;
  pres      record;
begin
  norm_code := upper(trim(coalesce(lookup_code, '')));

  -- Determine caller IP for rate limiting
  begin
    client_ip := current_setting('request.headers', true)::json->>'cf-connecting-ip';
    if client_ip is null or client_ip = '' then
      client_ip := current_setting('request.headers', true)::json->>'x-forwarded-for';
    end if;
  exception
    when others then client_ip := null;
  end;

  if client_ip is null or client_ip = '' then
    client_ip := coalesce(auth.uid()::text, 'anon');
  end if;

  rate_ok := public.check_code_lookup_rate_limit(client_ip);
  if not rate_ok then
    return jsonb_build_object('error', 'rate_limited', 'found', false);
  end if;

  select id, code, title, college, current_presentation_id, rating_open, show_scores, status
  into sess
  from public.sessions
  where code = norm_code;

  if not found then
    return jsonb_build_object('found', false);
  end if;

  if sess.current_presentation_id is not null then
    select id, name, position
    into pres
    from public.presentations
    where id = sess.current_presentation_id;
  end if;

  return jsonb_build_object(
    'found', true,
    'id', sess.id,
    'code', sess.code,
    'title', sess.title,
    'college', sess.college,
    'status', sess.status,
    'rating_open', sess.rating_open,
    'show_scores', sess.show_scores,
    'current_presentation', case
      when pres.id is not null then jsonb_build_object(
        'id', pres.id,
        'name', pres.name,
        'position', pres.position
      )
      else null
    end
  );
end;
$$;

-- ---------------------------------------------------------------- GET_STATS
-- Returns aggregated stats for a presentation: average, count, and individual star counts.
-- Aggregates only; raw voter rows are never returned.

create or replace function public.get_stats(presentation_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  result jsonb;
begin
  select jsonb_build_object(
    'presentation_id', get_stats.presentation_id,
    'count', count(r.id)::int,
    'average', coalesce(round(avg(r.stars)::numeric, 1), 0.0),
    'stars_1', count(r.id) filter (where r.stars = 1)::int,
    'stars_2', count(r.id) filter (where r.stars = 2)::int,
    'stars_3', count(r.id) filter (where r.stars = 3)::int,
    'stars_4', count(r.id) filter (where r.stars = 4)::int,
    'stars_5', count(r.id) filter (where r.stars = 5)::int
  )
  into result
  from public.ratings r
  where r.presentation_id = get_stats.presentation_id;

  return result;
end;
$$;

-- ---------------------------------------------------------------- GET_LEADERBOARD
-- Returns competition-ranked standings for the big screen leaderboard.
-- Ties receive the same place (e.g. 1, 1, 3).

create or replace function public.get_leaderboard(session_code text)
returns jsonb
language plpgsql
security definer
as $$
declare
  result jsonb;
begin
  with stats as (
    select
      p.id,
      p.name,
      p.position,
      count(r.id)::int as votes,
      coalesce(round(avg(r.stars)::numeric, 1), 0.0) as average
    from public.presentations p
    join public.sessions s on s.id = p.session_id
    left join public.ratings r on r.presentation_id = p.id
    where s.code = upper(trim(coalesce(session_code, '')))
    group by p.id, p.name, p.position
  ),
  ranked as (
    select
      id,
      name,
      position,
      votes,
      average,
      rank() over (order by average desc, votes desc, position asc) as place
    from stats
  )
  select coalesce(jsonb_agg(to_jsonb(r) order by place, position), '[]'::jsonb)
  into result
  from ranked r;

  return result;
end;
$$;

-- ---------------------------------------------------------------- RATE_PRESENTATION
-- Allows anonymous voters to submit/update their rating cleanly.
-- Triggers validate_rating_eligibility() to guarantee that session is live,
-- rating is open, and presentation is current.

create or replace function public.rate_presentation(presentation_id uuid, stars int)
returns jsonb
language plpgsql
security definer
as $$
declare
  sess_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select session_id into sess_id
  from public.presentations
  where id = rate_presentation.presentation_id;

  if not found then
    raise exception 'Presentation not found' using errcode = 'P0002';
  end if;

  insert into public.ratings (presentation_id, session_id, voter_id, stars)
  values (rate_presentation.presentation_id, sess_id, auth.uid(), rate_presentation.stars)
  on conflict (presentation_id, voter_id)
  do update set stars = excluded.stars, created_at = now();

  return jsonb_build_object('success', true, 'stars', rate_presentation.stars);
end;
$$;

-- ---------------------------------------------------------------- GET_MY_RATING
-- Allows a voter to read what they voted for a specific presentation.

create or replace function public.get_my_rating(presentation_id uuid)
returns jsonb
language plpgsql
security definer
as $$
declare
  my_stars int;
begin
  if auth.uid() is null then
    return jsonb_build_object('stars', null);
  end if;

  select stars into my_stars
  from public.ratings
  where presentation_id = get_my_rating.presentation_id
    and voter_id = auth.uid();

  return jsonb_build_object('stars', my_stars);
end;
$$;

-- Grant usage to public and authenticated roles
grant execute on function public.get_session_public(text) to anon, authenticated;
grant execute on function public.get_stats(uuid) to anon, authenticated;
grant execute on function public.get_leaderboard(text) to anon, authenticated;
grant execute on function public.rate_presentation(uuid, int) to anon, authenticated;
grant execute on function public.get_my_rating(uuid) to anon, authenticated;
