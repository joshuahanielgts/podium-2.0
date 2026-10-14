-- ============================================================================
-- FILE: supabase\migrations\20261015000000_schema.sql
-- ============================================================================

-- Podium â€” migration 001: Schema for Slido-style live rating tool
-- Drops any legacy tables safely and creates sessions, presentations, ratings, rate_limits

create extension if not exists "pgcrypto";

-- Clean drop of legacy and current tables in correct dependency order
drop table if exists public.ratings cascade;
drop table if exists public.presentations cascade;
drop table if exists public.sessions cascade;
drop table if exists public.rate_limits cascade;

-- Clean drop of old v1 tables if still around
drop table if exists public.votes cascade;
drop table if exists public.deck_pages cascade;
drop table if exists public.decks cascade;
drop table if exists public.results cascade;
drop table if exists public.event_members cascade;
drop table if exists public.events cascade;
drop table if exists public.profiles cascade;
drop schema if exists app cascade;

-- 1. SESSIONS
-- A session is created by a host (coordinator) with a 6-character code.
create table public.sessions (
  id                      uuid primary key default gen_random_uuid(),
  code                    text not null unique check (code ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$'),
  host_id                 uuid not null references auth.users(id) on delete cascade,
  title                   text not null check (char_length(title) between 1 and 100),
  college                 text check (char_length(college) <= 100),
  current_presentation_id uuid,
  rating_open             boolean not null default false,
  show_scores             boolean not null default true,
  status                  text not null default 'live' check (status in ('live', 'finished')),
  created_at              timestamptz not null default now()
);

-- 2. PRESENTATIONS
-- Teams presenting in the session, in order.
create table public.presentations (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references public.sessions(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 100),
  position    int not null default 0,
  created_at  timestamptz not null default now()
);

-- Circular FK for active presentation
alter table public.sessions
  add constraint fk_current_presentation
  foreign key (current_presentation_id) references public.presentations(id) on delete set null;

-- 3. RATINGS
-- 1 to 5 stars per phone (voter_id) per presentation.
-- Unique constraint enforces 1 rating per phone per presentation, allowing upsert.
create table public.ratings (
  id              uuid primary key default gen_random_uuid(),
  presentation_id uuid not null references public.presentations(id) on delete cascade,
  session_id      uuid not null references public.sessions(id) on delete cascade,
  voter_id        uuid not null references auth.users(id) on delete cascade,
  stars           int not null check (stars between 1 and 5),
  created_at      timestamptz not null default now(),
  unique (presentation_id, voter_id)
);

-- 4. RATE LIMITS
-- Track lookup attempts to prevent enumeration of codes
create table public.rate_limits (
  key        text primary key,
  count      int not null default 1,
  reset_at   timestamptz not null default (now() + interval '1 minute')
);

-- Indexes for fast queries
create index idx_sessions_code on public.sessions(code);
create index idx_sessions_host on public.sessions(host_id);
create index idx_presentations_session on public.presentations(session_id, position);
create index idx_ratings_presentation on public.ratings(presentation_id);
create index idx_ratings_session on public.ratings(session_id);
create index idx_ratings_voter on public.ratings(voter_id);

-- Realtime publication for live score updates
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  alter publication supabase_realtime add table public.sessions;
  alter publication supabase_realtime add table public.ratings;
exception
  when duplicate_object then null;
end $$;


-- ============================================================================
-- FILE: supabase\migrations\20261015000001_policies.sql
-- ============================================================================

-- Podium â€” migration 002: Row Level Security & Validation Trigger
-- Enforces all security and rating rules strictly in Postgres.

alter table public.sessions      enable row level security;
alter table public.presentations enable row level security;
alter table public.ratings       enable row level security;
alter table public.rate_limits   enable row level security;

-- ---------------------------------------------------------------- SESSIONS
-- Only the host who created the session can read and manage it directly.
-- Public audience members access safe session metadata via get_session_public().

drop policy if exists sessions_host_select on public.sessions;
create policy sessions_host_select on public.sessions
  for select using (host_id = (select auth.uid()));

drop policy if exists sessions_host_insert on public.sessions;
create policy sessions_host_insert on public.sessions
  for insert with check (host_id = (select auth.uid()));

drop policy if exists sessions_host_update on public.sessions;
create policy sessions_host_update on public.sessions
  for update using (host_id = (select auth.uid()))
  with check (host_id = (select auth.uid()));

drop policy if exists sessions_host_delete on public.sessions;
create policy sessions_host_delete on public.sessions
  for delete using (host_id = (select auth.uid()));

-- ---------------------------------------------------------------- PRESENTATIONS
-- Only the host can add, edit, or reorder presentations for their sessions.

drop policy if exists presentations_host_select on public.presentations;
create policy presentations_host_select on public.presentations
  for select using (
    exists (
      select 1 from public.sessions s
      where s.id = public.presentations.session_id
        and s.host_id = (select auth.uid())
    )
  );

drop policy if exists presentations_host_insert on public.presentations;
create policy presentations_host_insert on public.presentations
  for insert with check (
    exists (
      select 1 from public.sessions s
      where s.id = public.presentations.session_id
        and s.host_id = (select auth.uid())
    )
  );

drop policy if exists presentations_host_update on public.presentations;
create policy presentations_host_update on public.presentations
  for update using (
    exists (
      select 1 from public.sessions s
      where s.id = public.presentations.session_id
        and s.host_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.sessions s
      where s.id = public.presentations.session_id
        and s.host_id = (select auth.uid())
    )
  );

drop policy if exists presentations_host_delete on public.presentations;
create policy presentations_host_delete on public.presentations
  for delete using (
    exists (
      select 1 from public.sessions s
      where s.id = public.presentations.session_id
        and s.host_id = (select auth.uid())
    )
  );

-- ---------------------------------------------------------------- RATINGS
-- 1. Hosts can read raw ratings for their own sessions.
drop policy if exists ratings_host_select on public.ratings;
create policy ratings_host_select on public.ratings
  for select using (
    exists (
      select 1 from public.sessions s
      where s.id = public.ratings.session_id
        and s.host_id = (select auth.uid())
    )
  );

-- 2. Voters can only read their own rating row (e.g. to see what they rated).
drop policy if exists ratings_voter_select on public.ratings;
create policy ratings_voter_select on public.ratings
  for select using (voter_id = (select auth.uid()));

-- 3. Voters can insert their own rating row.
drop policy if exists ratings_insert on public.ratings;
create policy ratings_insert on public.ratings
  for insert with check (
    voter_id = (select auth.uid())
    and stars between 1 and 5
  );

-- 4. Voters can update their own rating row (changing their mind while open).
drop policy if exists ratings_update on public.ratings;
create policy ratings_update on public.ratings
  for update using (voter_id = (select auth.uid()))
  with check (
    voter_id = (select auth.uid())
    and stars between 1 and 5
  );

-- ---------------------------------------------------------------- TRIGGER FOR RATING ELIGIBILITY
-- Enforces:
-- - Rating must be for the CURRENT presentation of the session.
-- - Rating must be submitted while rating_open is true.
-- - Session must be in 'live' status.
-- - Presentation must belong to the session.

create or replace function public.check_rating_eligibility()
returns trigger
language plpgsql
security definer
as $$
declare
  sess record;
  pres record;
begin
  -- 1. Ensure caller is authenticated (either anonymous or signed in)
  if auth.uid() is null then
    raise exception 'Authentication required to submit rating' using errcode = '42501';
  end if;

  if new.voter_id <> auth.uid() then
    raise exception 'Cannot rate on behalf of another voter' using errcode = '42501';
  end if;

  -- 2. Check stars range
  if new.stars < 1 or new.stars > 5 then
    raise exception 'Rating must be between 1 and 5 stars' using errcode = '22023';
  end if;

  -- 3. Check session state
  select id, status, rating_open, current_presentation_id
  into sess
  from public.sessions
  where id = new.session_id;

  if not found then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  if sess.status <> 'live' then
    raise exception 'Session is finished' using errcode = '42501';
  end if;

  if not sess.rating_open then
    raise exception 'Rating is currently closed' using errcode = '42501';
  end if;

  if sess.current_presentation_id is null or sess.current_presentation_id <> new.presentation_id then
    raise exception 'This presentation is not currently open for rating' using errcode = '42501';
  end if;

  -- 4. Verify presentation belongs to this session
  select id into pres
  from public.presentations
  where id = new.presentation_id and session_id = new.session_id;

  if not found then
    raise exception 'Presentation does not belong to this session' using errcode = 'P0002';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_check_rating_eligibility on public.ratings;
create trigger trg_check_rating_eligibility
  before insert or update on public.ratings
  for each row execute function public.check_rating_eligibility();


-- ============================================================================
-- FILE: supabase\migrations\20261015000002_rpcs.sql
-- ============================================================================

-- Podium â€” migration 003: RPC functions for public session lookup, rating stats, and leaderboard
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


-- ============================================================================
-- FILE: supabase\migrations\20261015000003_keepalive.sql
-- ============================================================================

-- Podium â€” migration 004: keepalive heartbeat table
-- Prevents Supabase project auto-pausing after periods of inactivity.
-- Pinged every 3 days by .github/workflows/keep-supabase-awake.yml.

create table if not exists public.heartbeat (
  id        smallint primary key default 1 check (id = 1),
  last_seen timestamptz not null default now()
);

insert into public.heartbeat (id) values (1) on conflict do nothing;

alter table public.heartbeat enable row level security;

drop policy if exists heartbeat_read on public.heartbeat;
create policy heartbeat_read on public.heartbeat
  for select using (true);



