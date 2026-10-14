-- ============================================================================
-- Podium — Slido-style Live Rating: RLS & Invariant Verification Test Suite
-- ============================================================================
-- Can be executed in Supabase SQL editor or psql.
-- Rolls back at the end so it leaves no test data behind.

begin;

-- Helper to report test results
create temporary table test_results (
  test_num int,
  name text,
  passed boolean,
  details text
);

do $$
declare
  host_id  uuid := '11111111-1111-1111-1111-111111111111';
  voter1_id uuid := '22222222-2222-2222-2222-222222222222';
  voter2_id uuid := '33333333-3333-3333-3333-333333333333';
  stranger_id uuid := '44444444-4444-4444-4444-444444444444';
  
  sess_id  uuid;
  pres1_id uuid;
  pres2_id uuid;
  
  test_pass boolean;
  err_caught boolean;
  row_count int;
  stats_json jsonb;
  sess_json jsonb;
begin
  -- --------------------------------------------------------------------------
  -- SETUP: Create test session and 2 presentations as host
  -- --------------------------------------------------------------------------
  insert into public.sessions (id, code, host_id, title, college, rating_open, status)
  values (gen_random_uuid(), 'TEST99', host_id, 'Annual Pitch 2026', 'PSG Tech', false, 'live')
  returning id into sess_id;

  insert into public.presentations (id, session_id, name, position)
  values (gen_random_uuid(), sess_id, 'Team Alpha', 1)
  returning id into pres1_id;

  insert into public.presentations (id, session_id, name, position)
  values (gen_random_uuid(), sess_id, 'Team Beta', 2)
  returning id into pres2_id;

  -- Set active presentation to Team Alpha
  update public.sessions
  set current_presentation_id = pres1_id
  where id = sess_id;

  -- ==========================================================================
  -- TEST 1: Cannot rate when rating is closed
  -- ==========================================================================
  -- rating_open is currently false
  perform set_config('request.jwt.claim.sub', voter1_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  err_caught := false;
  begin
    insert into public.ratings (presentation_id, session_id, voter_id, stars)
    values (pres1_id, sess_id, voter1_id, 4);
  exception when others then
    err_caught := true;
  end;

  insert into test_results values (
    1,
    'Cannot rate when rating is closed',
    err_caught,
    case when err_caught then 'Rating rejected as expected' else 'FAILED: Rating was allowed when closed' end
  );

  -- ==========================================================================
  -- TEST 2: Cannot rate a non-current presentation
  -- ==========================================================================
  -- Open rating, but attempt to rate pres2 (Team Beta) while pres1 (Team Alpha) is current
  update public.sessions set rating_open = true where id = sess_id;

  err_caught := false;
  begin
    insert into public.ratings (presentation_id, session_id, voter_id, stars)
    values (pres2_id, sess_id, voter1_id, 5);
  exception when others then
    err_caught := true;
  end;

  insert into test_results values (
    2,
    'Cannot rate non-current presentation',
    err_caught,
    case when err_caught then 'Rating for non-current presentation rejected as expected' else 'FAILED: Rated non-current presentation' end
  );

  -- ==========================================================================
  -- TEST 3: Cannot send 0 or 6 stars
  -- ==========================================================================
  err_caught := false;
  begin
    insert into public.ratings (presentation_id, session_id, voter_id, stars)
    values (pres1_id, sess_id, voter1_id, 0);
  exception when others then
    err_caught := true;
  end;

  test_pass := err_caught;

  err_caught := false;
  begin
    insert into public.ratings (presentation_id, session_id, voter_id, stars)
    values (pres1_id, sess_id, voter1_id, 6);
  exception when others then
    err_caught := true;
  end;

  test_pass := test_pass and err_caught;

  insert into test_results values (
    3,
    'Cannot send 0 or 6 stars',
    test_pass,
    case when test_pass then '0 and 6 stars both rejected by constraint/trigger' else 'FAILED: Invalid star values accepted' end
  );

  -- ==========================================================================
  -- TEST 4: Legitimate vote succeeds & second vote updates (no duplicates)
  -- ==========================================================================
  -- First vote: 4 stars
  insert into public.ratings (presentation_id, session_id, voter_id, stars)
  values (pres1_id, sess_id, voter1_id, 4)
  on conflict (presentation_id, voter_id) do update
  set stars = excluded.stars;

  -- Second vote (voter changes mind to 5 stars)
  insert into public.ratings (presentation_id, session_id, voter_id, stars)
  values (pres1_id, sess_id, voter1_id, 5)
  on conflict (presentation_id, voter_id) do update
  set stars = excluded.stars;

  select count(*), max(stars) into row_count, err_caught
  from public.ratings
  where presentation_id = pres1_id and voter_id = voter1_id;

  test_pass := (row_count = 1) and (err_caught = 5);

  insert into test_results values (
    4,
    'Unique vote per voter updates rather than duplicates',
    test_pass,
    format('Row count: %s, Stars: %s', row_count, err_caught)
  );

  -- Add second voter's rating (4 stars)
  perform set_config('request.jwt.claim.sub', voter2_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  insert into public.ratings (presentation_id, session_id, voter_id, stars)
  values (pres1_id, sess_id, voter2_id, 4);

  -- ==========================================================================
  -- TEST 5: Non-host stranger cannot read raw ratings
  -- ==========================================================================
  perform set_config('request.jwt.claim.sub', stranger_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  select count(*) into row_count from public.ratings where session_id = sess_id;

  insert into test_results values (
    5,
    'Non-host stranger cannot read raw ratings',
    (row_count = 0),
    format('Stranger read %s rows (expected 0)', row_count)
  );

  -- Host CAN read raw ratings
  perform set_config('request.jwt.claim.sub', host_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  select count(*) into row_count from public.ratings where session_id = sess_id;

  insert into test_results values (
    6,
    'Host can read raw ratings for their session',
    (row_count = 2),
    format('Host read %s rows (expected 2)', row_count)
  );

  -- ==========================================================================
  -- TEST 6: get_stats returns aggregated results accurately
  -- ==========================================================================
  -- 2 ratings for Team Alpha: 5 stars and 4 stars -> Avg = 4.5, Count = 2
  stats_json := public.get_stats(pres1_id);

  test_pass := (stats_json->>'count')::int = 2
           and (stats_json->>'average')::numeric = 4.5
           and (stats_json->>'stars_4')::int = 1
           and (stats_json->>'stars_5')::int = 1
           and (stats_json->>'stars_1')::int = 0;

  insert into test_results values (
    7,
    'get_stats computes correct aggregates (Avg: 4.5, Count: 2)',
    test_pass,
    stats_json::text
  );

  -- ==========================================================================
  -- TEST 7: get_session_public returns safe metadata & masks for bad code
  -- ==========================================================================
  sess_json := public.get_session_public('TEST99');
  test_pass := (sess_json->>'found')::boolean = true
           and (sess_json->>'title') = 'Annual Pitch 2026'
           and (sess_json->'current_presentation'->>'name') = 'Team Alpha';

  sess_json := public.get_session_public('WRONG1');
  test_pass := test_pass and ((sess_json->>'found')::boolean = false);

  insert into test_results values (
    8,
    'get_session_public provides safe data & handles wrong codes',
    test_pass,
    'Valid code payload verified, invalid code returned found=false'
  );

end $$;

-- Display results
select
  test_num as "#",
  name as "Test Description",
  case when passed then 'PASS' else 'FAIL' end as "Result",
  details as "Details"
from test_results
order by test_num;

-- Clean rollback
rollback;
