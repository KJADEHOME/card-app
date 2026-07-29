-- TASK-CR-0102-B: profiles RLS security fix
-- Scope: policy and privilege changes only. No table/column/function changes.
-- Rollback: 0048_profiles_rls_security_fix_rollback.sql

BEGIN;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Remove every known historical profiles policy that grants broader or
-- overlapping access. IF EXISTS keeps the migration idempotent at policy level.
DROP POLICY IF EXISTS "Allow all" ON public.profiles;
DROP POLICY IF EXISTS "Users can view all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can delete own profile" ON public.profiles;
DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
DROP POLICY IF EXISTS "profiles_insert_own" ON public.profiles;
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;

-- Anonymous callers receive no profiles table privileges.
REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE public.profiles FROM anon;

-- Authenticated callers may read their own row and update only the two
-- self-service columns. Existing protect_sensitive_profile_fields trigger and
-- update_my_profile RPC remain unchanged as defense in depth.
REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE public.profiles FROM authenticated;
GRANT SELECT ON TABLE public.profiles TO authenticated;
GRANT UPDATE (username, avatar_url) ON TABLE public.profiles TO authenticated;

CREATE POLICY "profiles_select_own"
ON public.profiles
FOR SELECT
TO authenticated
USING (auth.uid() = id);

CREATE POLICY "profiles_update_own"
ON public.profiles
FOR UPDATE
TO authenticated
USING (auth.uid() = id)
WITH CHECK (auth.uid() = id);

COMMENT ON POLICY "profiles_select_own" ON public.profiles IS
  'CR-0102-B: authenticated users may select only their own profile; anon has no table privilege.';
COMMENT ON POLICY "profiles_update_own" ON public.profiles IS
  'CR-0102-B: own-row update plus column grants limited to username/avatar_url.';

-- No direct INSERT or DELETE policy is created. Profile creation must remain
-- in the existing trusted Auth synchronization path. Admin operations continue through
-- existing SECURITY DEFINER RPCs protected by require_admin().

COMMIT;

