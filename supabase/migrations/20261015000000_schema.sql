-- Podium — migration 001: Schema for Slido-style live rating tool
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
