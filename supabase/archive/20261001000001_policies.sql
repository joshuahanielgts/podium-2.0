-- Podium — migration 002: row-level security policies
-- Run after 20261001000000_schema.sql.
-- Every table is locked by default (RLS enabled) and then opened, statement
-- by statement, only as far as necessary.
--
-- BUGS FIXED from 02-policies.sql:
--   1. members_join: added stage check — you cannot join a draft event.
--   2. pages_write: now uses service-role-only path via Edge Function; the
--      client-side insert policy is removed (the process-deck function uses
--      service_role). Left a placeholder comment.
--   3. rate_limits table policies added.
--
-- The rule: the browser is never trusted. It can send any request it likes;
-- these policies decide what actually happens.

alter table public.profiles      enable row level security;
alter table public.events        enable row level security;
alter table public.event_members enable row level security;
alter table public.decks         enable row level security;
alter table public.deck_pages    enable row level security;
alter table public.votes         enable row level security;
alter table public.results       enable row level security;
alter table public.rate_limits   enable row level security;

-- ---------------------------------------------------------------- profiles
-- A person can always read their own row. An organiser can read the profiles
-- of everyone in their event (so the Teams and Voters dashboard tables work).
-- Nobody else can read anyone else's profile — Voters are anonymous to each other.
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select using (
    id = (select auth.uid())
    or exists (
      select 1
      from public.event_members mine
      join public.event_members theirs on theirs.event_id = mine.event_id
      where mine.profile_id  = (select auth.uid())
        and mine.role        = 'organiser'
        and theirs.profile_id = public.profiles.id
    )
  );

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles
  for insert with check (id = (select auth.uid()));

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update using (id = (select auth.uid()))
  with check    (id = (select auth.uid()));

-- ---------------------------------------------------------------- events
-- A listed (public) event is readable by everyone, including unauthenticated
-- visitors — the wall works for a room full of people who have not signed in.
-- A private (is_listed = false) event is readable only by its organiser or a
-- member. The code-lookup path goes through a security-definer RPC and the
-- rate-limited Edge Function, not through this policy.
drop policy if exists events_read on public.events;
create policy events_read on public.events
  for select using (
    is_listed
    or app.is_organiser(id)
    or exists (
      select 1 from public.event_members m
      where m.event_id   = public.events.id
        and m.profile_id = (select auth.uid())
    )
  );

-- Only a signed-in person can create an event, and they must set themselves
-- as the organiser_id. The claim_new_event trigger then adds the organiser
-- membership row automatically.
drop policy if exists events_create on public.events;
create policy events_create on public.events
  for insert with check (organiser_id = (select auth.uid()));

-- Only the organiser can change their own event.
drop policy if exists events_update on public.events;
create policy events_update on public.events
  for update using     (app.is_organiser(id))
  with check           (app.is_organiser(id));

-- ---------------------------------------------------------------- event_members
-- Anyone can read their own membership row. An organiser can read all rows for
-- their event (needed for the Teams/Voters dashboard tables).
drop policy if exists members_read on public.event_members;
create policy members_read on public.event_members
  for select using (
    profile_id = (select auth.uid())
    or app.is_organiser(event_id)
  );

-- Joining an event adds your own row as a voter.
-- BUG FIX: the original policy had no stage restriction — anyone could join a
-- draft event. Now joining requires the event to be open, in voting, or closed.
-- An organiser can also add/promote members (e.g. after an invite).
-- Nobody can write themselves in as an organiser: that role arrives only from
-- the creation trigger or from the organiser explicitly promoting someone.
drop policy if exists members_join on public.event_members;
create policy members_join on public.event_members
  for insert with check (
    -- A person can join as a voter, provided the event is past draft stage.
    (
      profile_id = (select auth.uid())
      and role = 'voter'
      and exists (
        select 1 from public.events e
        where e.id    = event_id
          and e.stage in ('open', 'voting', 'closed')
      )
    )
    -- The organiser can add or promote any member at any time.
    or app.is_organiser(event_id)
  );

-- Only the organiser can change a member's role (e.g. promote to organiser).
drop policy if exists members_manage on public.event_members;
create policy members_manage on public.event_members
  for update using     (app.is_organiser(event_id))
  with check           (app.is_organiser(event_id));

-- ---------------------------------------------------------------- decks
-- A live deck is readable by anyone who can read the event (visitor, voter,
-- organiser, member). A pending or hidden deck is visible only to its owner
-- and the organiser.
drop policy if exists decks_read on public.decks;
create policy decks_read on public.decks
  for select using (
    (status = 'live')
    or owner_id = (select auth.uid())
    or app.is_organiser(event_id)
  );

-- Upload rules (enforced in the DB, not only the interface):
--   • signed in and the owner_id matches
--   • a member of the event
--   • event is open or in voting
--   • uploads have not closed yet
--   • group_name (if set) must be one the organiser created
-- The unique (event_id, owner_id) constraint handles "one deck per team".
drop policy if exists decks_insert on public.decks;
create policy decks_insert on public.decks
  for insert with check (
    owner_id = (select auth.uid())
    and exists (
      select 1 from public.event_members m
      where m.event_id   = decks.event_id
        and m.profile_id = (select auth.uid())
    )
    and exists (
      select 1 from public.events e
      where e.id    = decks.event_id
        and e.stage in ('open', 'voting')
        and (e.uploads_close_at is null or now() <= e.uploads_close_at)
    )
    and (
      group_name is null
      or group_name = any (
        select unnest(e2.groups)
        from public.events e2
        where e2.id = decks.event_id
      )
    )
  );

-- A team can edit its own deck while uploads are open.
-- The organiser can change the deck's status (pending / live / hidden) at any time.
drop policy if exists decks_update on public.decks;
create policy decks_update on public.decks
  for update using (
    (
      owner_id = (select auth.uid())
      and exists (
        select 1 from public.events e
        where e.id = event_id
          and (e.uploads_close_at is null or now() <= e.uploads_close_at)
      )
    )
    or app.is_organiser(event_id)
  )
  with check (
    owner_id = (select auth.uid())
    or app.is_organiser(event_id)
  );

-- A team can delete its own deck (the FAQ promises this).
-- The organiser can also delete a deck.
drop policy if exists decks_delete on public.decks;
create policy decks_delete on public.decks
  for delete using (
    owner_id = (select auth.uid())
    or app.is_organiser(event_id)
  );

-- ---------------------------------------------------------------- deck_pages
-- Page images are readable by anyone who can read the deck.
drop policy if exists pages_read on public.deck_pages;
create policy pages_read on public.deck_pages
  for select using (
    exists (
      select 1 from public.decks d
      where d.id = deck_id
        and (
          d.status = 'live'
          or d.owner_id = (select auth.uid())
          or app.is_organiser(d.event_id)
        )
    )
  );

-- Page rows are written by the process-deck Edge Function using the
-- service_role key, which bypasses RLS. No client-side insert is allowed.
-- (If you ever need a client-side path, add a policy here.)

-- ---------------------------------------------------------------- votes
-- THE FIVE CONDITIONS of a vote, enforced where they cannot be skipped:
--   1. signed in (voter_id = auth.uid())
--   2. event stage is 'voting'
--   3. deck is live
--   4. voter does not own the deck
--   5. voter is a member of the event
-- The sixth — only once per deck — is the unique constraint in the schema.
drop policy if exists votes_insert on public.votes;
create policy votes_insert on public.votes
  for insert with check (
    voter_id = (select auth.uid())
    and app.event_is(event_id, 'voting')
    and exists (
      select 1 from public.decks d
      where d.id         = deck_id
        and d.event_id   = votes.event_id
        and d.status     = 'live'
        and d.owner_id  <> (select auth.uid())   -- no self-vote
    )
    and exists (
      select 1 from public.event_members m
      where m.event_id   = votes.event_id
        and m.profile_id = (select auth.uid())
    )
  );

-- Counts stay hidden until the organiser closes voting.
-- Before close: only the voter can see their own rows, and the organiser
--   sees all rows for their event.
-- After close ('closed'): everyone can read vote rows.
-- This policy + security_invoker on deck_counts is what keeps vote counts
-- invisible until the organiser presses "Close voting".
drop policy if exists votes_read on public.votes;
create policy votes_read on public.votes
  for select using (
    voter_id = (select auth.uid())
    or app.is_organiser(event_id)
    or app.event_is(event_id, 'closed')
  );

-- No update policy, no delete policy. The votes_no_change trigger (in the
-- schema migration) refuses both even if a policy is accidentally added later.

-- ---------------------------------------------------------------- results
-- Results are public once written (everyone can see the podium).
drop policy if exists results_read on public.results;
create policy results_read on public.results
  for select using (true);

-- Only the organiser can write or update the results snapshot.
drop policy if exists results_insert on public.results;
create policy results_insert on public.results
  for insert with check (app.is_organiser(event_id));

drop policy if exists results_update on public.results;
create policy results_update on public.results
  for update using     (app.is_organiser(event_id))
  with check           (app.is_organiser(event_id));

-- ---------------------------------------------------------------- rate_limits
-- The rate_limits table is written by the lookup-event Edge Function using
-- service_role, which bypasses RLS. No browser client reads or writes this.
-- RLS is enabled and no policies are created, so no direct access is possible.

-- ---------------------------------------------------------------- notes
-- The deck_counts view (security_invoker = on) runs as the CALLER, so a
-- visitor reading it before close sees zeros — the votes_read policy hides
-- the underlying vote rows from them. This is tested in supabase/tests/.
--
-- The service_role key bypasses every policy above and must NEVER appear in
-- this repository, in any GitHub workflow, or in any browser-accessible file.
