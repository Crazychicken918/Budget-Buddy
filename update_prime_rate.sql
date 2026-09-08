-- One-off update: refresh the shared South African prime rate.
--
-- bb_prime_rate is a single shared row (id = 1) that every prime-linked
-- loan reads from — updating it here ripples through every loan's rate
-- and payment across the whole app.
--
-- This is NOT part of schema.sql on purpose: schema.sql only seeds this
-- table once (insert ... on conflict do nothing) so that re-running
-- schema.sql for future migrations never stomps on a rate you've since
-- updated. Run this file by itself, in the Supabase SQL Editor, whenever
-- the prime rate actually changes — logged-in users are allowed to
-- update this table under RLS, so no service-role key is needed.
--
-- 2026-09-07: SARB repo rate 7.00% + 3.5% = prime 10.50%, unchanged since
-- a 25bp hike in May 2026 and held at the July 2026 MPC meeting.

update bb_prime_rate
set rate = 0.105,
    updated_at = now(),
    source = 'SARB — repo 7.00% + 3.5%, held at July 2026 MPC meeting'
where id = 1;
