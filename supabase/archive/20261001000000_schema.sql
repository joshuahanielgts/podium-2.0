-- Podium — migration 001: schema, tables, helpers, triggers
-- Run order matters. This file is safe to run on a fresh database and to
-- re-run on an existing one: every statement is guarded with IF (NOT) EXISTS
-- or CREATE OR REPLACE.
--
-- ORDER FIXED from 01-schema.sql:
--   The old file created app.votes_are_final() (line 130) before
--   `create schema app` (line 167), which fails on a clean database.
--   Here the schema and its grants come first, then extensions, then tables,
--   then helper functions, then triggers.

-- ---------------------------------------------------------------- private schema
-- Helper functions live here, not in public. PostgREST publishes `public` as
-- an HTTP API endpoint, so a helper in public would be callable by anyone at
-- /rest/v1/rpc/. The `app` schema is not published.
create schema if not exists app;
grant usage on schema app to anon, authenticated;

-- ---------------------------------------------------------------- extensions
create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- profiles
-- One row per signed-in person. id = auth user id, so a profile cannot exist
-- without an account behind it (cascade delete keeps it consistent).
create table if not exists public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  name        text not null check (char_length(name) between 2 and 60),
  college     text check (char_length(college) <= 80),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- events
-- stage is the single source of truth for what the wall and the policies allow.
-- The clock fields (voting_opens_at, voting_closes_at) are the intention; the
-- advance-stages Edge Function or pg_cron job moves stage to match them.
-- Manual organiser overrides call updateEvent() directly.
do $$ begin
  create type public.event_stage as enum ('draft', 'open', 'voting', 'closed');
exception when duplicate_object then null; end $$;

create table if not exists public.events (
  id                uuid primary key default gen_random_uuid(),

  -- Six characters from an alphabet with no O/I/0/1 (misread off a poster).
  -- ~1.07 billion combinations; unique only while the event is open.
  code              text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{6}$'),

  slug              text unique,
  organiser_id      uuid not null references public.profiles on delete restrict,
  name              text not null check (char_length(name) between 2 and 80),
  host              text not null check (char_length(host) <= 80),
  college           text check (char_length(college) <= 80),
  mode              text not null default 'offline'
                    check (mode in ('offline', 'online', 'hybrid')),
  venue             text check (char_length(venue) <= 120),
  meeting_url       text check (meeting_url ~* '^https?://'),
  signup_form_url   text check (signup_form_url ~* '^https?://'),
  fee_text          text check (char_length(fee_text) <= 40),

  -- Object keys in R2/storage, not public URLs. Signed URLs are generated at
  -- read time so the originals are never directly reachable.
  poster_key        text,
  banner_key        text,
  banner_preset     smallint check (banner_preset between 1 and 4),

  groups            text[] not null default '{}'
                    check (array_length(groups, 1) is null or array_length(groups, 1) <= 8),
  max_slides        smallint not null default 15 check (max_slides between 3 and 60),
  downloads_allowed boolean not null default false,
  is_listed         boolean not null default true,

  starts_at         timestamptz,
  uploads_close_at  timestamptz,
  voting_opens_at   timestamptz,
  voting_closes_at  timestamptz,

  stage             public.event_stage not null default 'draft',
  created_at        timestamptz not null default now(),

  -- Sanity checks on the time windows (enforced in the DB, not only the UI).
  constraint voting_window_sane check (
    voting_closes_at is null or voting_opens_at is null
    or voting_closes_at > voting_opens_at
  ),
  constraint uploads_before_voting check (
    uploads_close_at is null or voting_opens_at is null
    or voting_opens_at >= uploads_close_at
  )
);

-- Partial index: listed events are browsed by stage, unlisted ones are not.
create index if not exists events_stage_idx on public.events (stage) where is_listed;

-- ---------------------------------------------------------------- event_members
-- Why you are what you are. Role is determined by this table, never by the
-- browser. You are an organiser because you created the event (via a trigger);
-- a team because you uploaded a deck; a voter because you joined.
-- Nobody can INSERT themselves as an organiser — the policy enforces this.
do $$ begin
  create type public.member_role as enum ('organiser', 'team', 'voter');
exception when duplicate_object then null; end $$;

create table if not exists public.event_members (
  event_id   uuid not null references public.events on delete cascade,
  profile_id uuid not null references public.profiles on delete cascade,
  role       public.member_role not null default 'voter',
  joined_at  timestamptz not null default now(),
  primary key (event_id, profile_id)
);

create index if not exists event_members_profile_idx on public.event_members (profile_id);

-- ---------------------------------------------------------------- decks
-- unique (event_id, owner_id) = "one deck per team per event", enforced by the
-- database. A self-vote check compares d.owner_id = auth.uid() — a deck has
-- one owner. A deck_members table can be added later if multi-member teams are
-- needed, but the voting self-check would then need updating.
do $$ begin
  create type public.deck_status as enum ('pending', 'live', 'hidden');
exception when duplicate_object then null; end $$;

create table if not exists public.decks (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references public.events on delete cascade,
  owner_id     uuid not null references public.profiles on delete cascade,
  team         text not null check (char_length(team) between 2 and 60),
  college      text check (char_length(college) <= 80),
  group_name   text check (char_length(group_name) <= 24),
  one_liner    text check (char_length(one_liner) <= 90),

  -- The original file in R2 (private, deleted at 90 days).
  -- Rendered page images are in deck_pages; the wall never reads the original.
  file_key     text,
  page_count   smallint check (page_count between 1 and 200),

  status       public.deck_status not null default 'live',
  created_at   timestamptz not null default now(),

  unique (event_id, owner_id)   -- "one deck per team" enforced in the data
);

create index if not exists decks_event_idx on public.decks (event_id, status);

-- ---------------------------------------------------------------- deck_pages
-- One row per rendered page image. The wall reads these (via a signed URL),
-- never the original file. Written by the process-deck Edge Function after
-- the PDF is rendered.
create table if not exists public.deck_pages (
  deck_id     uuid not null references public.decks on delete cascade,
  page        smallint not null check (page between 1 and 200),
  image_key   text not null,    -- R2 object key for this page's WebP image
  width       smallint,
  height      smallint,
  primary key (deck_id, page)
);

-- ---------------------------------------------------------------- votes
-- The line the whole product rests on.
-- unique (event_id, voter_id, deck_id) = a second vote for the same deck
-- cannot be inserted, whatever the client sends.
create table if not exists public.votes (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references public.events on delete cascade,
  deck_id    uuid not null references public.decks on delete cascade,
  voter_id   uuid not null references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  unique (event_id, voter_id, deck_id)
);

create index if not exists votes_deck_idx  on public.votes (deck_id);
create index if not exists votes_event_idx on public.votes (event_id);
create index if not exists votes_voter_idx on public.votes (voter_id, event_id);

-- ---------------------------------------------------------------- results
-- Written once when the organiser closes voting. A disputed result has
-- something to show. The snapshot is immutable after writing; tie decisions
-- are stored separately (decided_by, decided_at, tie_note).
create table if not exists public.results (
  event_id    uuid primary key references public.events on delete cascade,
  snapshot    jsonb not null,      -- the full ranked list at close time
  tie_note    text,                -- 'joint' | 'organiser_call' | 'judges' | null
  decided_by  uuid references public.profiles,
  decided_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- rate_limits
-- Tracks code-lookup attempts per IP per minute so the lookup-event Edge
-- Function can refuse after ~10 tries/min without an external service.
-- Rows are cheap; a cleanup job prunes rows older than 10 minutes.
create table if not exists public.rate_limits (
  id         bigint primary key generated always as identity,
  key        text not null,           -- 'ip:<addr>' or 'uid:<uuid>'
  action     text not null default 'lookup',
  attempted_at timestamptz not null default now()
);

create index if not exists rate_limits_key_time on public.rate_limits (key, attempted_at);

-- ---------------------------------------------------------------- deck_counts (view)
-- Counts without exposing who voted for what.
-- security_invoker makes the view run as the CALLER, so it obeys the
-- votes RLS policy. Without it the view runs as its owner and leaks counts
-- before the organiser closes voting.
create or replace view public.deck_counts
  with (security_invoker = on) as
  select d.id as deck_id,
         d.event_id,
         count(v.id)::int as votes
  from public.decks d
  left join public.votes v on v.deck_id = d.id
  group by d.id, d.event_id;

-- ---------------------------------------------------------------- helper functions
-- All helpers are in the `app` schema (not `public`) so PostgREST does not
-- expose them as callable REST endpoints.

-- Is the calling user the organiser of the given event?
create or replace function app.is_organiser(target_event uuid)
  returns boolean
  language sql stable security definer
  set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.event_members m
    where m.event_id = target_event
      and m.profile_id = (select auth.uid())
      and m.role = 'organiser'
  );
$$;

-- Is the given event in the given stage?
create or replace function app.event_is(target_event uuid, want public.event_stage)
  returns boolean
  language sql stable security definer
  set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.events e
    where e.id = target_event and e.stage = want
  );
$$;

-- Safe event lookup by code. Returns only the public-safe subset so a rate-
-- limited Edge Function can call this without leaking private event details.
-- Returns NULL if the code does not match any non-closed event.
-- security definer so it can bypass the events_read policy — the rate limit
-- in the Edge Function is the actual gate.
create or replace function app.lookup_event_by_code(p_code text)
  returns table (
    id       uuid,
    slug     text,
    name     text,
    college  text,
    stage    public.event_stage
  )
  language sql stable security definer
  set search_path = public, pg_temp
as $$
  select e.id, e.slug, e.name, e.college, e.stage
  from public.events e
  where e.code = upper(p_code)
  limit 1;
$$;

-- Aggregate counts for the landing page (public, read-only, no PII).
create or replace function app.public_stats()
  returns table (events bigint, decks bigint, votes bigint)
  language sql stable security definer
  set search_path = public, pg_temp
as $$
  select
    (select count(*) from public.events where stage <> 'draft') as events,
    (select count(*) from public.decks   where status = 'live')  as decks,
    (select count(*) from public.votes)                           as votes;
$$;

-- Advance event stages based on the clock. Called by a scheduled job
-- (pg_cron or a scheduled Edge Function every few minutes). This is what
-- connects the organiser's time windows to the stage column that policies read.
create or replace function app.advance_stages()
  returns void
  language plpgsql security definer
  set search_path = public, pg_temp
as $$
begin
  -- open → voting when voting_opens_at has passed
  update public.events
  set stage = 'voting'
  where stage = 'open'
    and voting_opens_at is not null
    and voting_opens_at <= now();

  -- voting → closed when voting_closes_at has passed
  update public.events
  set stage = 'closed'
  where stage = 'voting'
    and voting_closes_at is not null
    and voting_closes_at <= now();
end;
$$;

-- ---------------------------------------------------------------- triggers

-- When a new event is created, its creator is automatically made an organiser
-- member so the RLS policies have something to read from the first request.
create or replace function app.claim_new_event()
  returns trigger
  language plpgsql security definer
  set search_path = public, pg_temp
as $$
begin
  insert into public.event_members (event_id, profile_id, role)
  values (new.id, new.organiser_id, 'organiser')
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists events_claim on public.events;
create trigger events_claim
  after insert on public.events
  for each row execute function app.claim_new_event();

-- A vote is never changed or deleted. There is no update/delete policy, and
-- this trigger refuses it even from a mistaken service-role call.
-- set search_path prevents search-path-injection attacks on privileged functions.
create or replace function app.votes_are_final()
  returns trigger
  language plpgsql
  set search_path = public, pg_temp
as $$
begin
  raise exception 'a vote cannot be changed or taken back';
end;
$$;

drop trigger if exists votes_no_change on public.votes;
create trigger votes_no_change
  before update or delete on public.votes
  for each row execute function app.votes_are_final();

-- When a deck row is inserted (by the upload flow), automatically add the
-- owner as a 'team' member if they are currently only a 'voter'.
-- This avoids a round-trip from the Edge Function.
create or replace function app.promote_uploader()
  returns trigger
  language plpgsql security definer
  set search_path = public, pg_temp
as $$
begin
  insert into public.event_members (event_id, profile_id, role)
  values (new.event_id, new.owner_id, 'team')
  on conflict (event_id, profile_id)
  do update set role = 'team'
  where public.event_members.role = 'voter';   -- don't downgrade an organiser
  return new;
end;
$$;

drop trigger if exists decks_promote on public.decks;
create trigger decks_promote
  after insert on public.decks
  for each row execute function app.promote_uploader();

-- Prune rate_limit rows older than 10 minutes to keep the table small.
-- Called by the advance-stages job so no extra cron slot is needed.
create or replace function app.prune_rate_limits()
  returns void
  language sql security definer
  set search_path = public, pg_temp
as $$
  delete from public.rate_limits where attempted_at < now() - interval '10 minutes';
$$;
