-- Podium — migration 003: keepalive heartbeat table
-- A free Supabase project pauses after 7 days of no database activity.
-- A college fest runs once a term, so the project would be paused on almost
-- every opening. This table gives the scheduled GitHub Action something to
-- read every 3 days, which counts as activity and keeps the project awake.
--
-- The scheduled workflow is in .github/workflows/keep-supabase-awake.yml.

create table if not exists public.heartbeat (
  id        smallint primary key default 1 check (id = 1),   -- one row only
  last_seen timestamptz not null default now()
);

-- Seed the row (harmless if it already exists).
insert into public.heartbeat (id) values (1) on conflict do nothing;

alter table public.heartbeat enable row level security;

-- The keep-alive Action uses the anon key, so the row must be publicly
-- readable. Nothing sensitive is in this table.
drop policy if exists heartbeat_read on public.heartbeat;
create policy heartbeat_read on public.heartbeat
  for select using (true);
