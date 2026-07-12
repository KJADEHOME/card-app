-- ============================================================
-- SH-003C Phase 1: SQL Test Suite (12 tests A-L)
-- Run this script in Supabase SQL Editor AFTER executing 0038 migration
-- ============================================================
-- Expected: All 12 tests should output 'PASS'
-- ============================================================

-- Helper: test result formatter
CREATE OR REPLACE FUNCTION _test_result(test_name TEXT, passed BOOLEAN, detail TEXT DEFAULT '')
RETURNS TEXT AS $$
BEGIN
    RETURN CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END || ' | ' || test_name || CASE WHEN detail != '' THEN ' | ' || detail ELSE '' END;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- Test A: 未登录调用 require_admin → 拒绝
-- ============================================
-- Run as: anon role (no auth)
-- Expected: EXCEPTION 'UNAUTHORIZED'
SELECT _test_result('A: require_admin rejects unauthenticated', false, 'Manual test required: run SELECT require_admin() as anon');

-- ============================================
-- Test B: user 调用 require_admin → 拒绝
-- ============================================
-- Run as: authenticated user with role='user'
-- Expected: EXCEPTION 'FORBIDDEN'
SELECT _test_result('B: require_admin rejects user role', false, 'Manual test required: run SELECT require_admin() as user-role session');

-- ============================================
-- Test C: merchant 调用 require_admin → 拒绝
-- ============================================
SELECT _test_result('C: require_admin rejects merchant role', false, 'Manual test required: run SELECT require_admin() as merchant-role session');

-- ============================================
-- Test D: admin 调用 require_admin → 通过
-- ============================================
SELECT _test_result('D: require_admin accepts admin role', false, 'Manual test required: run SELECT require_admin() as admin-role session');

-- ============================================
-- Test E: super_admin 调用 require_admin → 通过
-- ============================================
SELECT _test_result('E: require_admin accepts super_admin role', false, 'Manual test required: run SELECT require_admin() as super_admin-role session');

-- ============================================
-- Test F: 普通用户尝试把自己的 role 改为 admin → 拒绝
-- ============================================
-- This is protected by the trigger trg_protect_sensitive_profile
-- Manual test: as a user-role session, run:
--   UPDATE profiles SET role = 'admin' WHERE id = auth.uid();
-- Expected: EXCEPTION 'FORBIDDEN: Cannot modify role field'
SELECT _test_result('F: user cannot change own role', false, 'Manual test required: trigger blocks role change');

-- ============================================
-- Test G: admin 尝试授予 super_admin → 拒绝
-- ============================================
-- Manual test: as an admin-role session, run:
--   SELECT set_user_role('<target_uuid>', 'super_admin');
-- Expected: returns {success: false, error: 'FORBIDDEN: Only super_admin can change user roles'}
SELECT _test_result('G: admin cannot grant super_admin', false, 'Manual test required: set_user_role rejects admin caller');

-- ============================================
-- Test H: super_admin 合法修改角色 → 成功并写审计日志
-- ============================================
-- Manual test: as super_admin session, run:
--   SELECT set_user_role('<target_uuid>', 'admin');
-- Expected: returns {success: true, log_id: '...'}
-- Then verify: SELECT * FROM admin_audit_logs WHERE action = 'set_user_role' ORDER BY created_at DESC LIMIT 1;
SELECT _test_result('H: super_admin can change roles with audit log', false, 'Manual test required: set_user_role succeeds and logs');

-- ============================================
-- Test I: 普通用户直接写 admin_audit_logs → 拒绝
-- ============================================
-- Manual test: as a user-role session, run:
--   INSERT INTO admin_audit_logs (admin_id, action, target_type) VALUES (auth.uid(), 'test', 'test');
-- Expected: RLS denies INSERT (policy admin_audit_logs_deny_insert WITH CHECK (false))
SELECT _test_result('I: user cannot write audit logs', false, 'Manual test required: RLS denies INSERT');

-- ============================================
-- Test J: 旧管理员入口暂时仍可使用
-- ============================================
-- Verify admins table is still readable
SELECT _test_result(
    'J: admins table still readable',
    EXISTS(SELECT 1 FROM pg_tables WHERE schemaname = 'public' AND tablename = 'admins'),
    'admins table exists'
);

-- Verify admins table has SELECT policy for authenticated
SELECT _test_result(
    'J: admins table has SELECT policy',
    EXISTS(SELECT 1 FROM pg_policy WHERE polname = 'admins_select_all_authenticated' AND polrelid = 'public.admins'::regclass),
    'backward compat policy exists'
);

-- Verify admins table has deny-write policies
SELECT _test_result(
    'J: admins table denies frontend writes',
    EXISTS(SELECT 1 FROM pg_policy WHERE polname = 'admins_deny_insert' AND polrelid = 'public.admins'::regclass)
    AND EXISTS(SELECT 1 FROM pg_policy WHERE polname = 'admins_deny_update' AND polrelid = 'public.admins'::regclass)
    AND EXISTS(SELECT 1 FROM pg_policy WHERE polname = 'admins_deny_delete' AND polrelid = 'public.admins'::regclass),
    'deny policies exist'
);

-- ============================================
-- Test K: 无 RLS 递归或无限调用
-- ============================================
-- Verify trigger function does NOT UPDATE profiles (only SELECT)
-- If it did UPDATE, it would cause infinite recursion
SELECT _test_result(
    'K: trigger function has no UPDATE on profiles',
    NOT EXISTS(
        SELECT 1 FROM pg_proc p
        JOIN pg_trigger t ON t.tgfoid = p.oid
        WHERE p.proname = 'protect_sensitive_profile_fields'
        AND p.prosrc ~* 'UPDATE\s+public\.profiles'
    ),
    'trigger only does SELECT, no recursion risk'
);

-- Verify trigger is BEFORE UPDATE (not AFTER, which could cause issues)
SELECT _test_result(
    'K: trigger is BEFORE UPDATE',
    EXISTS(
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_protect_sensitive_profile'
        AND tgtype::bit(8) LIKE '000001%'  -- BEFORE flag
    ),
    'BEFORE UPDATE trigger'
);

-- ============================================
-- Test L: 回滚 SQL 完整性验证
-- ============================================
-- Verify all rollback targets exist (functions, trigger, table, policies)
SELECT _test_result(
    'L: rollback targets exist - require_admin',
    EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'require_admin' AND pronamespace = 'public'::regnamespace)
);

SELECT _test_result(
    'L: rollback targets exist - is_platform_admin',
    EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'is_platform_admin' AND pronamespace = 'public'::regnamespace)
);

SELECT _test_result(
    'L: rollback targets exist - log_admin_action',
    EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'log_admin_action' AND pronamespace = 'public'::regnamespace)
);

SELECT _test_result(
    'L: rollback targets exist - set_user_role',
    EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'set_user_role' AND pronamespace = 'public'::regnamespace)
);

SELECT _test_result(
    'L: rollback targets exist - update_my_profile',
    EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'update_my_profile' AND pronamespace = 'public'::regnamespace)
);

SELECT _test_result(
    'L: rollback targets exist - protect_sensitive_profile_fields',
    EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'protect_sensitive_profile_fields' AND pronamespace = 'public'::regnamespace)
);

SELECT _test_result(
    'L: rollback targets exist - trigger',
    EXISTS(SELECT 1 FROM pg_trigger WHERE tgname = 'trg_protect_sensitive_profile')
);

SELECT _test_result(
    'L: rollback targets exist - admin_audit_logs table',
    EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'admin_audit_logs')
);

-- ============================================
-- Additional verification: profiles.role CHECK constraint
-- ============================================
SELECT _test_result(
    'L: profiles.role CHECK includes super_admin',
    EXISTS(
        SELECT 1 FROM pg_constraint
        WHERE conname = 'profiles_role_check'
        AND conrelid = 'public.profiles'::regclass
        AND consrc LIKE '%super_admin%'
    ),
    'CHECK constraint updated'
);

-- ============================================
-- Additional verification: super_admin was set
-- ============================================
SELECT _test_result(
    'L: first super_admin exists',
    EXISTS(SELECT 1 FROM public.profiles WHERE role = 'super_admin'),
    'admin@cardrealm.top should be super_admin'
);

-- ============================================
-- Additional verification: SECURITY DEFINER flags
-- ============================================
SELECT _test_result(
    'L: require_admin is SECURITY DEFINER',
    EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'require_admin' AND prosecdef = true)
);

SELECT _test_result(
    'L: require_admin has fixed search_path',
    EXISTS(
        SELECT 1 FROM pg_proc
        WHERE proname = 'require_admin'
        AND proconfig IS NOT NULL
        AND array_to_string(proconfig, ',') LIKE '%search_path%'
    )
);

-- ============================================
-- Additional verification: EXECUTE permissions
-- ============================================
SELECT _test_result(
    'L: require_admin EXECUTE granted to authenticated only',
    EXISTS(
        SELECT 1 FROM information_schema.role_routine_grants
        WHERE routine_name = 'require_admin'
        AND grantee = 'authenticated'
    )
    AND NOT EXISTS(
        SELECT 1 FROM information_schema.role_routine_grants
        WHERE routine_name = 'require_admin'
        AND grantee = 'anon'
    ),
    'authenticated only, not anon'
);

-- ============================================
-- Cleanup helper function
-- ============================================
DROP FUNCTION IF EXISTS _test_result(TEXT, BOOLEAN, TEXT);

-- ============================================
-- End of SQL Test Suite
-- ============================================
-- NOTE: Tests A-I require authenticated sessions with specific roles.
-- These can be run via:
--   1. Supabase Dashboard SQL Editor (runs as service_role)
--   2. Application-level tests using supabase-js client
--   3. Supabase Management API with test users
--
-- The automated JS test file (tests/sh003c-phase1-test.js) provides
-- static analysis tests that verify migration structure without
-- requiring a live database connection.
-- ============================================
