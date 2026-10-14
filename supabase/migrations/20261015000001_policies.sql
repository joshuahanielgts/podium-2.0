-- Podium — migration 002: Row Level Security & Validation Trigger
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
