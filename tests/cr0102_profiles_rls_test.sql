-- TASK-CR-0102-B profiles RLS security tests
-- Required: execute only in an isolated staging database after migration 0048.
-- The script discovers existing fixtures, performs checks in one transaction,
-- and always rolls back. It must not be used to deploy or mutate production.

BEGIN;

CREATE TEMP TABLE cr0102_fixture (
  user_a uuid NOT NULL,
  user_b uuid NOT NULL,
  admin_id uuid NOT NULL
) ON COMMIT DROP;

DO $$
DECLARE
  v_user_a uuid;
  v_user_b uuid;
  v_admin uuid;
BEGIN
  SELECT id INTO v_user_a FROM public.profiles WHERE role = 'user' ORDER BY id LIMIT 1;
  SELECT id INTO v_user_b FROM public.profiles WHERE role = 'user' AND id <> v_user_a ORDER BY id LIMIT 1;
  SELECT id INTO v_admin FROM public.profiles WHERE role IN ('admin', 'super_admin') ORDER BY id LIMIT 1;
  IF v_user_a IS NULL OR v_user_b IS NULL OR v_admin IS NULL THEN
    RAISE EXCEPTION 'CR0102 fixtures missing: require two users and one admin in isolated staging';
  END IF;
  INSERT INTO cr0102_fixture VALUES (v_user_a, v_user_b, v_admin);
END $$;

GRANT SELECT ON cr0102_fixture TO anon, authenticated;

-- Case 1: anon sees zero profiles.
SET LOCAL ROLE anon;
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.profiles;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL Case 1: anon read % profile rows', v_count; END IF;
  RAISE NOTICE 'PASS Case 1: anon reads zero profiles';
END $$;
RESET ROLE;

-- Case 2: user A cannot read user B.
SELECT set_config('request.jwt.claims', json_build_object('sub', user_a, 'role', 'authenticated')::text, true)
FROM cr0102_fixture;
SET LOCAL ROLE authenticated;
DO $$
DECLARE v_user_b uuid; v_count integer;
BEGIN
  SELECT user_b INTO v_user_b FROM cr0102_fixture;
  SELECT count(*) INTO v_count FROM public.profiles WHERE id = v_user_b;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL Case 2: user A can read user B'; END IF;
  RAISE NOTICE 'PASS Case 2: cross-user read denied';
END $$;

-- Case 3: user A can read own profile.
DO $$
DECLARE v_user_a uuid; v_count integer;
BEGIN
  SELECT user_a INTO v_user_a FROM cr0102_fixture;
  SELECT count(*) INTO v_count FROM public.profiles WHERE id = v_user_a;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL Case 3: own profile row count %', v_count; END IF;
  RAISE NOTICE 'PASS Case 3: own profile readable';
END $$;

-- Case 4: user A cannot update role. Column privileges and the existing
-- protect_sensitive_profile_fields trigger both remain defenses.
DO $$
DECLARE v_user_a uuid; v_blocked boolean := false;
BEGIN
  SELECT user_a INTO v_user_a FROM cr0102_fixture;
  BEGIN
    UPDATE public.profiles SET role = 'admin' WHERE id = v_user_a;
  EXCEPTION WHEN insufficient_privilege THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL Case 4: role update was not denied'; END IF;
  RAISE NOTICE 'PASS Case 4: role update denied';
END $$;
RESET ROLE;

-- Case 5: an admin identity passes the unchanged require_admin() boundary and
-- can read its own profile. Cross-user admin reads remain RPC-only.
SELECT set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true)
FROM cr0102_fixture;
SET LOCAL ROLE authenticated;
DO $$
DECLARE v_admin uuid; v_required uuid; v_count integer;
BEGIN
  SELECT admin_id INTO v_admin FROM cr0102_fixture;
  SELECT public.require_admin() INTO v_required;
  IF v_required <> v_admin THEN RAISE EXCEPTION 'FAIL Case 5: require_admin mismatch'; END IF;
  SELECT count(*) INTO v_count FROM public.profiles WHERE id = v_admin;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL Case 5: admin own profile unavailable'; END IF;
  RAISE NOTICE 'PASS Case 5: admin boundary and own-profile access';
END $$;
RESET ROLE;

ROLLBACK;

