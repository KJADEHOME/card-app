const fs = require('fs');
const assert = require('assert');

let passed = 0;
function test(name, fn) {
  try { fn(); console.log('PASS', name); passed++; }
  catch (e) { console.error('FAIL', name, e.message); process.exitCode = 1; }
}
function text(path) { return fs.readFileSync(path, 'utf8'); }

const login = text('admin-platform-login.html');
const publish = text('admin-platform-publish.html');
const recharge = text('admin-recharge.html');
const merchant = text('admin-merchant.html');
const m40 = text('supabase/migrations/0040_admin_rpc_group_a.sql');
const m41 = text('supabase/migrations/0041_admin_rpc_group_b.sql');
const m42 = text('supabase/migrations/0042_admin_rpc_group_c.sql');
const m43 = text('supabase/migrations/0043_admin_rpc_group_d_disable.sql');

test('login uses Supabase Auth', () => assert(login.includes('signInWithPassword')));
test('login requires AdminAuth', () => assert(login.includes('AdminAuth.requireAdmin')));
test('login has no legacy RPC', () => assert(!login.includes("rpc('admin_login'")));
test('login stores no platform token', () => assert(!login.includes('platformAdminToken')));
test('publish uses AdminAuth', () => assert(publish.includes('AdminAuth.requireAdmin')));
test('publish sends no admin token', () => assert(!publish.includes('p_admin_token')));
test('publish logout uses Supabase Auth', () => assert(publish.includes('AdminAuth.logout')));
test('recharge sends no frontend admin uid', () => assert(!recharge.includes('p_admin_uid')));
test('merchant sends no frontend admin id', () => assert(!merchant.includes('p_admin_id')));

test('0040 authenticates via require_admin', () => assert(m40.includes('v_admin_id := public.require_admin()')));
test('0040 revokes legacy login', () => assert(m40.includes('REVOKE ALL ON FUNCTION public.admin_login')));
test('0040 grants secure publish only to authenticated', () => assert(m40.includes('GRANT EXECUTE ON FUNCTION public.admin_publish_card')));
test('0041 locks recharge rows', () => assert((m41.match(/FOR UPDATE/g)||[]).length >= 2));
test('0041 disables old admin uid overloads', () => assert(m41.includes('approve_recharge(UUID,UUID)')));
test('0042 uses controlled admin marker', () => assert(m42.includes("cardrealm.controlled_admin_rpc")));
test('0042 secure user functions call require_admin', () => assert((m42.match(/public\.require_admin\(\)/g)||[]).length >= 4));
test('0042 disables old merchant overload', () => assert(m42.includes('admin_verify_merchant(UUID,UUID,TEXT,TEXT,TEXT)')));
test('0043 disables eight zombie RPC names', () => {
  const names = ['admin_update_platform_card','admin_confirm_pre_order','admin_bulk_list_cards','admin_create_sealed_product','admin_update_sealed_product','admin_confirm_sealed_order','admin_create_merchandise','admin_update_merchandise'];
  names.forEach(n => assert(m43.includes(`'${n}'`), n));
});

test('all migrations use transactions', () => [m40,m41,m42,m43].forEach(s => { assert(s.includes('BEGIN;')); assert(s.includes('COMMIT;')); }));

if (process.exitCode) process.exit(1);
console.log(`\n${passed} tests passed`);
