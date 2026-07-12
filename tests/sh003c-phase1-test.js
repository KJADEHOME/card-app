/**
 * SH-003C Phase 1 — Static Analysis Test Suite
 *
 * 12 tests (A-L) verifying migration SQL structure and admin-auth.js module.
 * These tests perform static analysis (no live database required).
 * Live DB tests are in supabase/migrations/test_0038_sh003c_phase1.sql
 *
 * Run: node tests/sh003c-phase1-test.js
 */

const fs = require('fs');
const path = require('path');

const BASE_DIR = path.resolve(__dirname, '..');
const MIGRATION_PATH = path.join(BASE_DIR, 'supabase', 'migrations', '0038_admin_auth_unification_phase1.sql');
const ADMIN_AUTH_PATH = path.join(BASE_DIR, 'js', 'admin-auth.js');
const TEST_SQL_PATH = path.join(BASE_DIR, 'supabase', 'migrations', 'test_0038_sh003c_phase1.sql');

let passCount = 0;
let failCount = 0;
const results = [];

function assert(condition, testName, detail = '') {
    if (condition) {
        passCount++;
        results.push(`  PASS | ${testName}`);
    } else {
        failCount++;
        results.push(`  FAIL | ${testName}${detail ? ' | ' + detail : ''}`);
    }
}

function assertContains(haystack, needle, testName) {
    const found = haystack.includes(needle);
    assert(found, testName, found ? '' : `Expected to find: "${needle.substring(0, 80)}..."`);
}

function assertNotContains(haystack, needle, testName) {
    const found = haystack.includes(needle);
    assert(!found, testName, found ? `Should NOT contain: "${needle.substring(0, 80)}..."` : '');
}

// ============================================================
// Load files
// ============================================================

let migrationSQL = '';
let adminAuthJS = '';
let testSQL = '';

try {
    migrationSQL = fs.readFileSync(MIGRATION_PATH, 'utf8');
} catch (e) {
    console.error('FATAL: Cannot read migration file:', MIGRATION_PATH);
    process.exit(1);
}

try {
    adminAuthJS = fs.readFileSync(ADMIN_AUTH_PATH, 'utf8');
} catch (e) {
    console.error('FATAL: Cannot read admin-auth.js:', ADMIN_AUTH_PATH);
    process.exit(1);
}

try {
    testSQL = fs.readFileSync(TEST_SQL_PATH, 'utf8');
} catch (e) {
    console.error('FATAL: Cannot read test SQL file:', TEST_SQL_PATH);
    process.exit(1);
}

console.log('\n============================================================');
console.log('SH-003C Phase 1 — Static Analysis Test Suite (12 tests)');
console.log('============================================================\n');

// ============================================================
// Test A: require_admin rejects unauthenticated
// ============================================================
console.log('Test A: require_admin rejects unauthenticated');

assertContains(migrationSQL, "v_uid UUID := auth.uid();", 'A.1: require_admin uses auth.uid()');
assertContains(migrationSQL, "IF v_uid IS NULL THEN", 'A.2: require_admin checks NULL uid');
assertContains(migrationSQL, "'UNAUTHORIZED: Not authenticated'", 'A.3: require_admin raises UNAUTHORIZED');
assertContains(migrationSQL, "USING ERRCODE = '42501'", 'A.4: require_admin uses correct ERRCODE');

// ============================================================
// Test B: require_admin rejects user role
// ============================================================
console.log('Test B: require_admin rejects user role');

assertContains(migrationSQL, "v_role NOT IN ('admin', 'super_admin')", 'B.1: require_admin checks role whitelist');
assertContains(migrationSQL, "'FORBIDDEN: Admin access required'", 'B.2: require_admin raises FORBIDDEN');
assert(
    migrationSQL.includes("SELECT role INTO v_role\n    FROM public.profiles\n    WHERE id = v_uid"),
    'B.3: require_admin queries profiles table by auth.uid()'
);

// ============================================================
// Test C: require_admin rejects merchant role
// ============================================================
console.log('Test C: require_admin rejects merchant role');

// Same check as B — merchant is not in ('admin', 'super_admin')
assert(
    !migrationSQL.includes("v_role NOT IN ('admin', 'super_admin', 'merchant')"),
    'C.1: merchant is NOT in the admin whitelist'
);
assertContains(migrationSQL, "v_role IS NULL OR v_role NOT IN", 'C.2: NULL role also rejected');

// ============================================================
// Test D: require_admin accepts admin role
// ============================================================
console.log('Test D: require_admin accepts admin role');

assertContains(migrationSQL, "'admin', 'super_admin'", 'D.1: admin is in accepted roles');
assertContains(migrationSQL, "RETURN v_uid;", 'D.2: require_admin returns UUID on success');

// ============================================================
// Test E: require_admin accepts super_admin role
// ============================================================
console.log('Test E: require_admin accepts super_admin role');

assertContains(migrationSQL, "super_admin", 'E.1: super_admin in role whitelist');
assertContains(migrationSQL, "CHECK (role IN ('user', 'merchant', 'admin', 'super_admin'))", 'E.2: profiles.role CHECK includes super_admin');

// ============================================================
// Test F: user cannot change own role
// ============================================================
console.log('Test F: user cannot change own role');

assertContains(migrationSQL, "protect_sensitive_profile_fields", 'F.1: trigger function exists');
assertContains(migrationSQL, "BEFORE UPDATE ON public.profiles", 'F.2: trigger is BEFORE UPDATE');
assertContains(migrationSQL, "trg_protect_sensitive_profile", 'F.3: trigger is attached');
assertContains(migrationSQL, "NEW.role IS DISTINCT FROM OLD.role", 'F.4: trigger checks role change');
assertContains(migrationSQL, "'FORBIDDEN: Cannot modify role field'", 'F.5: trigger blocks role change with error');

// Verify trigger also protects other sensitive fields
assertContains(migrationSQL, "NEW.is_disabled IS DISTINCT FROM OLD.is_disabled", 'F.6: trigger protects is_disabled');
assertContains(migrationSQL, "NEW.disabled_reason IS DISTINCT FROM OLD.disabled_reason", 'F.7: trigger protects disabled_reason');
assertContains(migrationSQL, "NEW.disabled_at IS DISTINCT FROM OLD.disabled_at", 'F.8: trigger protects disabled_at');
assertContains(migrationSQL, "NEW.disabled_by IS DISTINCT FROM OLD.disabled_by", 'F.9: trigger protects disabled_by');
assertContains(migrationSQL, "NEW.merchant_verified IS DISTINCT FROM OLD.merchant_verified", 'F.10: trigger protects merchant_verified');
assertContains(migrationSQL, "NEW.merchant_verified_by IS DISTINCT FROM OLD.merchant_verified_by", 'F.11: trigger protects merchant_verified_by');

// ============================================================
// Test G: admin cannot grant super_admin
// ============================================================
console.log('Test G: admin cannot grant super_admin');

assertContains(migrationSQL, "set_user_role", 'G.1: set_user_role function exists');
assertContains(migrationSQL, "v_caller_role != 'super_admin'", 'G.2: set_user_role checks caller is super_admin');
assertContains(migrationSQL, "'FORBIDDEN: Only super_admin can change user roles'", 'G.3: set_user_role rejects non-super_admin');

// Verify denied attempts are logged
assertContains(migrationSQL, "set_user_role_DENIED", 'G.4: denied attempts are logged to audit');
assertContains(migrationSQL, "p_new_role NOT IN ('user', 'merchant', 'admin', 'super_admin')", 'G.5: role value validated against whitelist');

// ============================================================
// Test H: super_admin can change roles with audit log
// ============================================================
console.log('Test H: super_admin can change roles with audit log');

assertContains(migrationSQL, "UPDATE public.profiles\n    SET role = p_new_role", 'H.1: set_user_role updates profiles');
assertContains(migrationSQL, "INSERT INTO public.admin_audit_logs", 'H.2: set_user_role writes audit log');
assertContains(migrationSQL, "'set_user_role'", 'H.3: audit action is set_user_role');
assertContains(migrationSQL, "jsonb_build_object('old_role', v_old_role, 'new_role', p_new_role)", 'H.4: audit log includes old and new role');
assertContains(migrationSQL, "RETURNING id INTO v_log_id", 'H.5: returns log_id');

// ============================================================
// Test I: user cannot write admin_audit_logs
// ============================================================
console.log('Test I: user cannot write admin_audit_logs');

assertContains(migrationSQL, "admin_audit_logs_deny_insert", 'I.1: deny INSERT policy exists');
assertContains(migrationSQL, "admin_audit_logs_deny_update", 'I.2: deny UPDATE policy exists');
assertContains(migrationSQL, "admin_audit_logs_deny_delete", 'I.3: deny DELETE policy exists');
assertContains(migrationSQL, "FOR INSERT WITH CHECK (false)", 'I.4: INSERT denied with false CHECK');
assertContains(migrationSQL, "FOR UPDATE USING (false) WITH CHECK (false)", 'I.5: UPDATE denied with false');
assertContains(migrationSQL, "FOR DELETE USING (false)", 'I.6: DELETE denied with false');
assertContains(migrationSQL, "ENABLE ROW LEVEL SECURITY", 'I.7: RLS enabled on audit table');

// Verify sensitive data stripping
assertContains(migrationSQL, "'password' - 'password_hash' - 'token'", 'I.8: sensitive keys stripped in log_admin_action');

// ============================================================
// Test J: old admin entry still works
// ============================================================
console.log('Test J: old admin entry still works');

assertContains(migrationSQL, "admins_select_all_authenticated", 'J.1: admins table has SELECT policy for authenticated');
assertContains(migrationSQL, "FOR SELECT TO authenticated USING (true)", 'J.2: SELECT allowed for backward compat');
assertContains(migrationSQL, "DEPRECATED (SH-003C Phase 1)", 'J.3: admins table marked as deprecated');
assertNotContains(migrationSQL, "DROP TABLE public.admins", 'J.4: admins table NOT dropped');
assertNotContains(migrationSQL, "DELETE FROM public.admins", 'J.5: admins data NOT deleted');

// Verify deny-write policies don't break SELECT
assertContains(migrationSQL, "admins_deny_insert", 'J.6: admins denies INSERT');
assertContains(migrationSQL, "admins_deny_update", 'J.7: admins denies UPDATE');
assertContains(migrationSQL, "admins_deny_delete", 'J.8: admins denies DELETE');

// ============================================================
// Test K: no RLS recursion or infinite calls
// ============================================================
console.log('Test K: no RLS recursion or infinite calls');

// Verify trigger function does NOT contain UPDATE on profiles (would cause recursion)
const triggerFuncMatch = migrationSQL.match(/protect_sensitive_profile_fields\(\)[\s\S]*?AS\s*\$\$([\s\S]*?)\$\$/);
if (triggerFuncMatch) {
    const triggerBody = triggerFuncMatch[1];
    assertNotContains(triggerBody, 'UPDATE public.profiles', 'K.1: trigger function has no UPDATE on profiles');
    assertNotContains(triggerBody, 'UPDATE profiles', 'K.2: trigger function has no UPDATE on profiles (unqualified)');
    assertContains(triggerBody, 'SELECT role INTO v_role', 'K.3: trigger does SELECT (safe, no recursion)');
    assertContains(triggerBody, 'FROM public.profiles', 'K.3b: trigger reads from profiles (SELECT only)');
} else {
    assert(false, 'K.1: could not extract trigger function body');
}

// Verify require_admin does not call itself
const requireAdminMatch = migrationSQL.match(/require_admin\(\)[\s\S]*?AS\s*\$\$([\s\S]*?)\$\$/);
if (requireAdminMatch) {
    const funcBody = requireAdminMatch[1];
    assertNotContains(funcBody, 'require_admin()', 'K.4: require_admin does not call itself');
} else {
    assert(false, 'K.4: could not extract require_admin body');
}

// Verify set_user_role calls require_admin but not itself (except in audit log strings)
const setUserRoleMatch = migrationSQL.match(/set_user_role\([\s\S]*?AS\s*\$\$([\s\S]*?)\$\$/);
if (setUserRoleMatch) {
    const funcBody = setUserRoleMatch[1];
    // Remove audit log string literals before checking for self-calls
    const funcBodyNoStrings = funcBody.replace(/'[^']*'/g, "''");
    assertNotContains(funcBodyNoStrings, 'set_user_role(', 'K.5: set_user_role does not call itself');
} else {
    assert(false, 'K.5: could not extract set_user_role body');
}

// ============================================================
// Test L: rollback SQL completeness
// ============================================================
console.log('Test L: rollback SQL completeness');

// Extract rollback section
const rollbackMatch = migrationSQL.match(/ROLLBACK SQL[\s\S]*?END ROLLBACK/);
if (rollbackMatch) {
    const rollbackSQL = rollbackMatch[0];

    assertContains(rollbackSQL, "DROP FUNCTION IF EXISTS public.set_user_role", 'L.1: rollback drops set_user_role');
    assertContains(rollbackSQL, "DROP FUNCTION IF EXISTS public.update_my_profile", 'L.2: rollback drops update_my_profile');
    assertContains(rollbackSQL, "DROP TRIGGER IF EXISTS trg_protect_sensitive_profile", 'L.3: rollback drops trigger');
    assertContains(rollbackSQL, "DROP FUNCTION IF EXISTS public.protect_sensitive_profile_fields", 'L.4: rollback drops trigger function');
    assertContains(rollbackSQL, "DROP FUNCTION IF EXISTS public.log_admin_action", 'L.5: rollback drops log_admin_action');
    assertContains(rollbackSQL, "DROP FUNCTION IF EXISTS public.is_platform_admin", 'L.6: rollback drops is_platform_admin');
    assertContains(rollbackSQL, "DROP FUNCTION IF EXISTS public.require_admin", 'L.7: rollback drops require_admin');
    assertContains(rollbackSQL, "DROP TABLE IF EXISTS public.admin_audit_logs", 'L.8: rollback drops admin_audit_logs');
    assertContains(rollbackSQL, "DROP POLICY IF EXISTS \"admins_deny_delete\"", 'L.9: rollback removes admins deny policies');
    assertContains(rollbackSQL, "DROP POLICY IF EXISTS \"profiles_update_own\"", 'L.10: rollback removes profiles UPDATE policy');
    assertContains(rollbackSQL, "CHECK (role IN ('user', 'merchant', 'admin'))", 'L.11: rollback restores old CHECK constraint');
    assertContains(rollbackSQL, "role = 'admin'", 'L.12: rollback reverts super_admin to admin');
    assertContains(rollbackSQL, "Users can update own profile", 'L.13: rollback restores old UPDATE policy');
} else {
    assert(false, 'L.0: could not find ROLLBACK SQL section');
}

// ============================================================
// Additional: SECURITY DEFINER and search_path verification
// ============================================================
console.log('\n--- Additional Security Verification ---');

assertContains(migrationSQL, "SECURITY DEFINER\nSET search_path = public, auth", 'S.1: require_admin has SECURITY DEFINER + fixed search_path');
assertContains(migrationSQL, "REVOKE ALL ON FUNCTION public.require_admin() FROM PUBLIC", 'S.2: require_admin EXECUTE revoked from PUBLIC');
assertContains(migrationSQL, "REVOKE ALL ON FUNCTION public.require_admin() FROM anon", 'S.3: require_admin EXECUTE revoked from anon');
assertContains(migrationSQL, "GRANT EXECUTE ON FUNCTION public.require_admin() TO authenticated", 'S.4: require_admin EXECUTE granted to authenticated only');

assertContains(migrationSQL, "REVOKE ALL ON FUNCTION public.set_user_role", 'S.5: set_user_role EXECUTE revoked from PUBLIC/anon');
assertContains(migrationSQL, "REVOKE ALL ON FUNCTION public.log_admin_action", 'S.6: log_admin_action EXECUTE revoked from PUBLIC/anon');

// ============================================================
// Additional: admin-auth.js module verification
// ============================================================
console.log('\n--- admin-auth.js Module Verification ---');

assertContains(adminAuthJS, "const AdminAuth = (() => {", 'M.1: AdminAuth module defined');
assertContains(adminAuthJS, "requireAdmin", 'M.2: requireAdmin method exported');
assertContains(adminAuthJS, "check()", 'M.3: check method exported');
assertContains(adminAuthJS, "logAction", 'M.4: logAction method exported');
assertContains(adminAuthJS, "isPlatformAdmin", 'M.5: isPlatformAdmin method exported');
assertContains(adminAuthJS, "setUserRole", 'M.6: setUserRole method exported');
assertContains(adminAuthJS, "updateMyProfile", 'M.7: updateMyProfile method exported');
assertContains(adminAuthJS, "logout", 'M.8: logout method exported');

// Verify fail-closed behavior
assertContains(adminAuthJS, "window.supabase === 'undefined'", 'M.9: fail-closed checks supabase SDK');
assertContains(adminAuthJS, "document.body.replaceChildren", 'M.10: fail-closed replaces page body');
assertContains(adminAuthJS, "throw new Error", 'M.11: fail-closed throws error');
assertContains(adminAuthJS, "window.RiskControl === 'undefined'", 'M.12: fail-closed checks RiskControl');

// Verify no frontend-supplied user ID is trusted
assertNotContains(adminAuthJS, "p_user_id", 'M.13: no user_id parameter accepted');
assertNotContains(adminAuthJS, "userId", 'M.14: no userId parameter in auth checks');

// Verify column selection is correct (no dropped columns)
assertContains(adminAuthJS, "id, role, username, avatar_url, is_disabled, merchant_verified", 'M.15: correct profiles columns selected');
assertNotContains(adminAuthJS, "merchant_name", 'M.16: does not select dropped column merchant_name');
assertNotContains(adminAuthJS, "merchant_badge", 'M.17: does not select dropped column merchant_badge');

// Verify RPC calls
assertContains(adminAuthJS, "client.rpc('require_admin')", 'M.18: calls require_admin RPC');
assertContains(adminAuthJS, "client.rpc('log_admin_action'", 'M.19: calls log_admin_action RPC');
assertContains(adminAuthJS, "client.rpc('is_platform_admin')", 'M.20: calls is_platform_admin RPC');
assertContains(adminAuthJS, "client.rpc('set_user_role'", 'M.21: calls set_user_role RPC');
assertContains(adminAuthJS, "client.rpc('update_my_profile'", 'M.22: calls update_my_profile RPC');

// ============================================================
// Additional: Pre-flight checks verification
// ============================================================
console.log('\n--- Pre-flight Checks Verification ---');

assertContains(migrationSQL, "PREREQUISITE FAILED: public.profiles table does not exist", 'P.1: pre-flight checks profiles table');
assertContains(migrationSQL, "PREREQUISITE FAILED: profiles.role column does not exist", 'P.2: pre-flight checks role column');
assertContains(migrationSQL, "PREFLIGHT FAILED: Found", 'P.3: pre-flight checks invalid role data');
assertContains(migrationSQL, "v_invalid_count > 0", 'P.4: pre-flight aborts on invalid data');

// ============================================================
// Additional: update_my_profile whitelist verification
// ============================================================
console.log('\n--- update_my_profile Whitelist Verification ---');

assertContains(migrationSQL, "p_username", 'W.1: update_my_profile accepts username');
assertContains(migrationSQL, "p_avatar_url", 'W.2: update_my_profile accepts avatar_url');
assertNotContains(migrationSQL, "p_role", 'W.3: update_my_profile does NOT accept role');
assertNotContains(migrationSQL, "p_is_disabled", 'W.4: update_my_profile does NOT accept is_disabled');
assertNotContains(migrationSQL, "p_disabled_reason", 'W.5: update_my_profile does NOT accept disabled_reason');
assertNotContains(migrationSQL, "p_merchant_verified", 'W.6: update_my_profile does NOT accept merchant_verified');

// ============================================================
// Print results
// ============================================================

console.log('\n============================================================');
console.log('RESULTS');
console.log('============================================================');
results.forEach(r => console.log(r));
console.log('------------------------------------------------------------');
console.log(`Total: ${passCount + failCount} | PASS: ${passCount} | FAIL: ${failCount}`);
console.log('============================================================\n');

if (failCount > 0) {
    console.error('❌ SOME TESTS FAILED — DO NOT proceed to Phase 2');
    process.exit(1);
} else {
    console.log('✅ ALL TESTS PASSED — Phase 1 static analysis verified');
    process.exit(0);
}
