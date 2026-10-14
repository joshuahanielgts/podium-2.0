-- Podium — migration 004: keepalive heartbeat table
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
