-- ============================================================
-- 0038: Admin Auth Unification — Phase 1 (SH-003C)
--
-- Principles:
--   * ADD only — do not modify existing RPC, business tables, or pricing
--   * Old admins table remains functional (deprecated marker only)
--   * All new objects have explicit RLS and tightened EXECUTE grants
--   * Full rollback SQL at bottom
--   * Pre-flight checks abort migration if prerequisites not met
--
-- Sensitive fields protected (users CANNOT self-modify):
--   role, is_disabled, disabled_reason, disabled_at, disabled_by,
--   merchant_verified, merchant_verified_by
--
-- Date: 2026-07-13
-- ============================================================

-- ============================================
-- Part 0: Pre-flight checks
-- ============================================

-- 0.1 Verify profiles table exists
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_schema = 'public' AND table_name = 'profiles') THEN
        RAISE EXCEPTION 'PREREQUISITE FAILED: public.profiles table does not exist. Run 0032 migration first.';
    END IF;
END;
$$;

-- 0.2 Verify profiles.role column exists
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = 'profiles' AND column_name = 'role') THEN
        RAISE EXCEPTION 'PREREQUISITE FAILED: profiles.role column does not exist. Run 0032 migration first.';
    END IF;
END;
$$;

-- 0.3 Scan existing role data for invalid values — abort if found
DO $$
DECLARE
    v_invalid_count INTEGER;
    v_invalid_samples TEXT;
BEGIN
    SELECT COUNT(*), COALESCE(string_agg(DISTINCT role, ', '), '') INTO v_invalid_count, v_invalid_samples
    FROM public.profiles
    WHERE role IS NOT NULL
      AND role NOT IN ('user', 'merchant', 'admin', 'super_admin');

    IF v_invalid_count > 0 THEN
        RAISE EXCEPTION
            'PREFLIGHT FAILED: Found % profiles with invalid role values: [%]. '
            'Migration aborted. Fix these records before retrying.',
            v_invalid_count, v_invalid_samples;
    END IF;
END;
$$;

-- ============================================
-- Part 1: Expand profiles.role CHECK + add updated_at column
-- ============================================

-- 1.0 Add updated_at column (did not exist in original schema)
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

-- 1.1 Expand role CHECK to include super_admin
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;

ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_role_check
    CHECK (role IN ('user', 'merchant', 'admin', 'super_admin'));

COMMENT ON COLUMN public.profiles.role IS
    'User role: user=普通用户, merchant=商家(含平台自营), admin=管理员, super_admin=超级管理员';

-- ============================================
-- Part 2: Create admin_audit_logs table
-- ============================================

CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
    id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
    admin_id    UUID        REFERENCES auth.users(id) ON DELETE SET NULL,
    action      TEXT        NOT NULL,
    target_type TEXT        NOT NULL,
    target_id   UUID,
    details     JSONB       DEFAULT '{}'::jsonb,
    ip_address  TEXT,
    user_agent  TEXT,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_admin
    ON public.admin_audit_logs(admin_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_action
    ON public.admin_audit_logs(action, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_target
    ON public.admin_audit_logs(target_type, target_id)
    WHERE target_id IS NOT NULL;

-- 2.1 Enable RLS
ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;

-- 2.2 RLS: READ — only admins/super_admin can read
CREATE POLICY "admin_audit_logs_select_admin" ON public.admin_audit_logs
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid()
              AND p.role IN ('admin', 'super_admin')
        )
    );

-- 2.3 RLS: Deny ALL direct INSERT/UPDATE/DELETE from anon/authenticated
--      Only service_role (bypasses RLS) or SECURITY DEFINER RPCs can write
CREATE POLICY "admin_audit_logs_deny_insert" ON public.admin_audit_logs
    FOR INSERT WITH CHECK (false);

CREATE POLICY "admin_audit_logs_deny_update" ON public.admin_audit_logs
    FOR UPDATE USING (false) WITH CHECK (false);

CREATE POLICY "admin_audit_logs_deny_delete" ON public.admin_audit_logs
    FOR DELETE USING (false);

COMMENT ON TABLE public.admin_audit_logs IS
    'SH-003C: Admin operation audit log. Frontend CANNOT INSERT/UPDATE/DELETE — only service_role or SECURITY DEFINER RPCs (log_admin_action, set_user_role) can write. Sensitive data (passwords, keys, payment details) is stripped server-side.';

-- ============================================
-- Part 3: require_admin() — unified auth check
-- ============================================

CREATE OR REPLACE FUNCTION public.require_admin()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid  UUID := auth.uid();
    v_role TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Not authenticated'
            USING ERRCODE = '42501';
    END IF;

    SELECT role INTO v_role
    FROM public.profiles
    WHERE id = v_uid;

    IF v_role IS NULL OR v_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'FORBIDDEN: Admin access required'
            USING ERRCODE = '42501';
    END IF;

    RETURN v_uid;
END;
$$;

REVOKE ALL ON FUNCTION public.require_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.require_admin() FROM anon;
GRANT EXECUTE ON FUNCTION public.require_admin() TO authenticated;

COMMENT ON FUNCTION public.require_admin() IS
    'SH-003C: Unified admin auth check. SECURITY DEFINER. No parameters — uses auth.uid() only. Returns admin UUID or raises FORBIDDEN.';

-- ============================================
-- Part 4: is_platform_admin() — super_admin check
-- ============================================

CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid  UUID := auth.uid();
    v_role TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RETURN FALSE;
    END IF;

    SELECT role INTO v_role
    FROM public.profiles
    WHERE id = v_uid;

    RETURN v_role = 'super_admin';
END;
$$;

REVOKE ALL ON FUNCTION public.is_platform_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_platform_admin() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_platform_admin() TO authenticated;

COMMENT ON FUNCTION public.is_platform_admin() IS
    'SH-003C: Returns TRUE if current user has super_admin role. Used for platform-level operations.';

-- ============================================
-- Part 5: log_admin_action() — controlled audit log writer
-- ============================================

CREATE OR REPLACE FUNCTION public.log_admin_action(
    p_action      TEXT,
    p_target_type TEXT,
    p_target_id   UUID DEFAULT NULL,
    p_details     JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_admin_uid UUID;
    v_log_id    UUID;
    v_action    TEXT;
    v_tgt_type  TEXT;
BEGIN
    v_admin_uid := public.require_admin();

    v_action   := LEFT(BTRIM(p_action), 100);
    v_tgt_type := LEFT(BTRIM(p_target_type), 50);

    IF v_action IS NULL OR v_action = '' THEN
        RAISE EXCEPTION 'INVALID: action cannot be empty' USING ERRCODE = '22004';
    END IF;

    IF v_tgt_type IS NULL OR v_tgt_type = '' THEN
        v_tgt_type := 'unknown';
    END IF;

    -- Strip sensitive keys (defense-in-depth, even if caller included them)
    p_details := p_details
        - 'password' - 'password_hash' - 'token' - 'session_token'
        - 'secret' - 'api_key' - 'private_key' - 'signing_key'
        - 'card_number' - 'cvv' - 'stripe_token' - 'payment_intent_id';

    INSERT INTO public.admin_audit_logs (
        admin_id, action, target_type, target_id, details
    )
    VALUES (
        v_admin_uid, v_action, v_tgt_type, p_target_id, p_details
    )
    RETURNING id INTO v_log_id;

    RETURN v_log_id;
END;
$$;

REVOKE ALL ON FUNCTION public.log_admin_action(TEXT, TEXT, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_admin_action(TEXT, TEXT, UUID, JSONB) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_admin_action(TEXT, TEXT, UUID, JSONB) TO authenticated;

COMMENT ON FUNCTION public.log_admin_action(TEXT, TEXT, UUID, JSONB) IS
    'SH-003C: Controlled audit log writer. Calls require_admin() internally. Strips sensitive keys.';

-- ============================================
-- Part 6: Sensitive field protection trigger
-- ============================================

-- 6.1 Trigger function: block non-super_admin from changing sensitive fields
CREATE OR REPLACE FUNCTION public.protect_sensitive_profile_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid       UUID := auth.uid();
    v_role      TEXT;
BEGIN
    -- If no session user (service_role / migration context), allow
    IF v_uid IS NULL THEN
        RETURN NEW;
    END IF;

    -- Look up caller's role (bypasses RLS via SECURITY DEFINER)
    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;

    -- super_admin can change anything (via set_user_role RPC)
    IF v_role = 'super_admin' THEN
        RETURN NEW;
    END IF;

    -- For everyone else: block changes to sensitive fields
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify role field' USING ERRCODE = '42501';
    END IF;

    IF NEW.is_disabled IS DISTINCT FROM OLD.is_disabled THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify is_disabled field' USING ERRCODE = '42501';
    END IF;

    IF NEW.disabled_reason IS DISTINCT FROM OLD.disabled_reason THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify disabled_reason field' USING ERRCODE = '42501';
    END IF;

    IF NEW.disabled_at IS DISTINCT FROM OLD.disabled_at THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify disabled_at field' USING ERRCODE = '42501';
    END IF;

    IF NEW.disabled_by IS DISTINCT FROM OLD.disabled_by THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify disabled_by field' USING ERRCODE = '42501';
    END IF;

    IF NEW.merchant_verified IS DISTINCT FROM OLD.merchant_verified THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify merchant_verified field' USING ERRCODE = '42501';
    END IF;

    IF NEW.merchant_verified_by IS DISTINCT FROM OLD.merchant_verified_by THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify merchant_verified_by field' USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$;

-- 6.2 Attach trigger to profiles table
DROP TRIGGER IF EXISTS trg_protect_sensitive_profile ON public.profiles;
CREATE TRIGGER trg_protect_sensitive_profile
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_sensitive_profile_fields();

COMMENT ON FUNCTION public.protect_sensitive_profile_fields() IS
    'SH-003C: Trigger function that blocks non-super_admin users from modifying sensitive profile fields (role, is_disabled, disabled_*, merchant_verified*). service_role (auth.uid()=NULL) and super_admin bypass.';

-- ============================================
-- Part 7: Harden profiles UPDATE RLS
-- ============================================

-- 7.1 Drop the existing permissive UPDATE policy (from 0036)
DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;

-- 7.2 New UPDATE policy: user can update own profile
--     Trigger (Part 6) handles sensitive field protection at row level
--     RLS provides the first layer: only own profile
CREATE POLICY "profiles_update_own" ON public.profiles
    FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

COMMENT ON POLICY "profiles_update_own" ON public.profiles IS
    'SH-003C: Users can update own profile. Sensitive fields protected by trigger trg_protect_sensitive_profile.';

-- ============================================
-- Part 8: update_my_profile() — controlled self-service update
-- ============================================

CREATE OR REPLACE FUNCTION public.update_my_profile(
    p_username   TEXT DEFAULT NULL,
    p_avatar_url TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_count INTEGER;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
    END IF;

    -- Build update dynamically, only touching whitelisted fields
    IF p_username IS NOT NULL THEN
        p_username := LEFT(BTRIM(p_username), 50);
        IF p_username = '' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Username cannot be empty');
        END IF;

        -- Check uniqueness (excluding self)
        SELECT COUNT(*) INTO v_count
        FROM public.profiles
        WHERE username = p_username AND id != v_uid;

        IF v_count > 0 THEN
            RETURN jsonb_build_object('success', false, 'error', 'Username already taken');
        END IF;

        UPDATE public.profiles SET username = p_username, updated_at = NOW() WHERE id = v_uid;
    END IF;

    IF p_avatar_url IS NOT NULL THEN
        -- Basic length limit (URL validation handled by app layer / safeUrl)
        p_avatar_url := LEFT(BTRIM(p_avatar_url), 500);
        UPDATE public.profiles SET avatar_url = p_avatar_url, updated_at = NOW() WHERE id = v_uid;
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.update_my_profile(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_my_profile(TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_my_profile(TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.update_my_profile(TEXT, TEXT) IS
    'SH-003C: Controlled self-service profile update. Only whitelisted fields (username, avatar_url). Sensitive fields are NOT accepted.';

-- ============================================
-- Part 9: set_user_role() — super_admin only role management
-- ============================================

CREATE OR REPLACE FUNCTION public.set_user_role(
    p_target_id UUID,
    p_new_role  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller_uid UUID;
    v_caller_role TEXT;
    v_target_exists BOOLEAN;
    v_old_role TEXT;
    v_log_id UUID;
BEGIN
    -- 1. Verify caller is authenticated
    v_caller_uid := auth.uid();
    IF v_caller_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
    END IF;

    -- 2. Verify caller is super_admin (NOT just admin)
    SELECT role INTO v_caller_role
    FROM public.profiles
    WHERE id = v_caller_uid;

    IF v_caller_role IS NULL OR v_caller_role != 'super_admin' THEN
        -- Log the denied attempt
        BEGIN
            INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
            VALUES (
                v_caller_uid,
                'set_user_role_DENIED',
                'user',
                p_target_id,
                jsonb_build_object('requested_role', p_new_role, 'caller_role', v_caller_role)
            );
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN: Only super_admin can change user roles');
    END IF;

    -- 3. Validate new role value
    IF p_new_role NOT IN ('user', 'merchant', 'admin', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid role value');
    END IF;

    -- 4. Verify target user exists
    SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id = p_target_id) INTO v_target_exists;
    IF NOT v_target_exists THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target user not found');
    END IF;

    -- 5. Get old role for audit
    SELECT role INTO v_old_role FROM public.profiles WHERE id = p_target_id;

    -- 6. Update role (trigger allows this because caller is super_admin)
    UPDATE public.profiles
    SET role = p_new_role, updated_at = NOW()
    WHERE id = p_target_id;

    -- 7. Write audit log
    INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
    VALUES (
        v_caller_uid,
        'set_user_role',
        'user',
        p_target_id,
        jsonb_build_object('old_role', v_old_role, 'new_role', p_new_role)
    )
    RETURNING id INTO v_log_id;

    RETURN jsonb_build_object(
        'success', true,
        'log_id', v_log_id,
        'old_role', v_old_role,
        'new_role', p_new_role
    );
END;
$$;

REVOKE ALL ON FUNCTION public.set_user_role(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_user_role(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_user_role(UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.set_user_role(UUID, TEXT) IS
    'SH-003C: Super_admin only. Changes a user role. Logs to admin_audit_logs. Denied attempts are also logged.';

-- ============================================
-- Part 10: Set first super_admin (one-time controlled SQL)
-- ============================================

-- Set admin@cardrealm.top to super_admin
-- This is the bootstrap: only this migration can create the first super_admin
-- After this, only set_user_role() (called by a super_admin) can change roles
UPDATE public.profiles
SET role = 'super_admin', updated_at = NOW()
WHERE id IN (
    SELECT id FROM auth.users WHERE email = 'admin@cardrealm.top'
)
AND (role IS NULL OR role NOT IN ('super_admin'));

-- ============================================
-- Part 11: Mark admins table as deprecated (read-only)
-- ============================================

COMMENT ON TABLE public.admins IS
    'DEPRECATED (SH-003C Phase 1): Migrated to profiles.role. This table is retained read-only for historical audit. Do NOT authenticate through this table.';

-- 11.1 Enable RLS on admins table if not already enabled
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_tables
        WHERE schemaname = 'public' AND tablename = 'admins' AND rowsecurity = true
    ) THEN
        ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
    END IF;
END;
$$;

-- 11.2 Backward-compat: authenticated users can still SELECT
DROP POLICY IF EXISTS "admins_select_all_authenticated" ON public.admins;
CREATE POLICY "admins_select_all_authenticated" ON public.admins
    FOR SELECT TO authenticated USING (true);

-- 11.3 Deny all frontend writes (service_role bypasses RLS for emergencies)
DROP POLICY IF EXISTS "admins_deny_insert" ON public.admins;
CREATE POLICY "admins_deny_insert" ON public.admins
    FOR INSERT TO authenticated WITH CHECK (false);

DROP POLICY IF EXISTS "admins_deny_update" ON public.admins;
CREATE POLICY "admins_deny_update" ON public.admins
    FOR UPDATE TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS "admins_deny_delete" ON public.admins;
CREATE POLICY "admins_deny_delete" ON public.admins
    FOR DELETE TO authenticated USING (false);

COMMENT ON POLICY "admins_select_all_authenticated" ON public.admins IS 'SH-003C: Backward compat — old admin pages can still read.';
COMMENT ON POLICY "admins_deny_insert" ON public.admins IS 'SH-003C: Deprecated — no frontend writes.';
COMMENT ON POLICY "admins_deny_update" ON public.admins IS 'SH-003C: Deprecated — no frontend writes.';
COMMENT ON POLICY "admins_deny_delete" ON public.admins IS 'SH-003C: Deprecated — no frontend writes.';

-- ============================================
-- Part 12: Verification helpers (run manually post-migration)
-- ============================================

-- 12.1 Verify require_admin is SECURITY DEFINER with correct search_path
-- SELECT proname, prosecdef, proconfig FROM pg_proc WHERE proname = 'require_admin';

-- 12.2 Verify trigger exists
-- SELECT tgname, tgrelid::regclass, tgenabled FROM pg_trigger WHERE tgname = 'trg_protect_sensitive_profile';

-- 12.3 Verify admin_audit_logs RLS
-- SELECT tablename, rowsecurity FROM pg_tables WHERE tablename = 'admin_audit_logs';

-- 12.4 Verify super_admin was set
-- SELECT id, role FROM public.profiles WHERE role = 'super_admin';

-- 12.5 Verify admins table comment
-- SELECT obj_description('public.admins'::regclass, 'pg_class');

-- ============================================
-- ROLLBACK SQL — restores pre-Phase-1 state
-- ============================================
--
-- -- Part 11: Restore admins table
-- DROP POLICY IF EXISTS "admins_deny_delete" ON public.admins;
-- DROP POLICY IF EXISTS "admins_deny_update" ON public.admins;
-- DROP POLICY IF EXISTS "admins_deny_insert" ON public.admins;
-- DROP POLICY IF EXISTS "admins_select_all_authenticated" ON public.admins;
-- COMMENT ON TABLE public.admins IS '平台独立管理员系统（与 auth.users 隔离）';
--
-- -- Part 10: Revert super_admin back to admin
-- UPDATE public.profiles SET role = 'admin'
-- WHERE id IN (SELECT id FROM auth.users WHERE email = 'admin@cardrealm.top')
-- AND role = 'super_admin';
--
-- -- Part 9: Drop set_user_role
-- DROP FUNCTION IF EXISTS public.set_user_role(UUID, TEXT) CASCADE;
--
-- -- Part 8: Drop update_my_profile
-- DROP FUNCTION IF EXISTS public.update_my_profile(TEXT, TEXT) CASCADE;
--
-- -- Part 7: Restore old profiles UPDATE policy
-- DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
-- CREATE POLICY "Users can update own profile" ON public.profiles
--     FOR UPDATE USING (auth.uid() = id) WITH CHECK (auth.uid() = id);
--
-- -- Part 6: Drop trigger and function
-- DROP TRIGGER IF EXISTS trg_protect_sensitive_profile ON public.profiles;
-- DROP FUNCTION IF EXISTS public.protect_sensitive_profile_fields() CASCADE;
--
-- -- Part 5: Drop log_admin_action
-- DROP FUNCTION IF EXISTS public.log_admin_action(TEXT, TEXT, UUID, JSONB) CASCADE;
--
-- -- Part 4: Drop is_platform_admin
-- DROP FUNCTION IF EXISTS public.is_platform_admin() CASCADE;
--
-- -- Part 3: Drop require_admin
-- DROP FUNCTION IF EXISTS public.require_admin() CASCADE;
--
-- -- Part 2: Drop admin_audit_logs
-- DROP TABLE IF EXISTS public.admin_audit_logs CASCADE;
--
-- -- Part 1: Restore old CHECK constraint + drop updated_at
-- ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
-- ALTER TABLE public.profiles
--     ADD CONSTRAINT profiles_role_check
--     CHECK (role IN ('user', 'merchant', 'admin'));
-- COMMENT ON COLUMN public.profiles.role IS '用户角色: user=普通用户, merchant=商家(含平台自营), admin=超级管理员';
-- ALTER TABLE public.profiles DROP COLUMN IF EXISTS updated_at;
--
-- -- Also delete js/admin-auth.js from the project
--
-- -- END ROLLBACK
-- ============================================
