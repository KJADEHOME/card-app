const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const migration = fs.readFileSync(path.join(root, 'supabase/migrations/0044_financial_fk_safety.sql'), 'utf8');
const rollback = fs.readFileSync(path.join(root, 'supabase/migrations/0044_financial_fk_safety_rollback.sql'), 'utf8');
const validation = fs.readFileSync(path.join(root, 'supabase/migrations/test_0044_financial_fk_safety.sql'), 'utf8');

const checks = [
  ['escrow order SET NULL', /escrow_records_order_id_fkey[\s\S]*ON DELETE SET NULL/i.test(migration)],
  ['escrow buyer SET NULL', /escrow_records_buyer_id_fkey[\s\S]*ON DELETE SET NULL/i.test(migration)],
  ['escrow seller SET NULL', /escrow_records_seller_id_fkey[\s\S]*ON DELETE SET NULL/i.test(migration)],
  ['refund order SET NULL', /refunds_order_id_fkey[\s\S]*ON DELETE SET NULL/i.test(migration)],
  ['dispute order SET NULL', /disputes_order_id_fkey[\s\S]*ON DELETE SET NULL/i.test(migration)],
  ['snapshot columns added', /order_no_snapshot/i.test(migration) && /buyer_id_snapshot/i.test(migration)],
  ['NOT NULL dropped', /ALTER COLUMN order_id DROP NOT NULL/i.test(migration)],
  ['constraints validated', /VALIDATE CONSTRAINT/i.test(migration)],
  ['pre-flight fail closed', /pre-flight failed/i.test(migration)],
  ['rollback fail closed', /rollback aborted/i.test(rollback)],
  ['production validation present', /set_null_fk_status/i.test(validation)],
  ['transaction boundaries', /^BEGIN;/m.test(migration) && /COMMIT;/m.test(migration)],
];

let failed = 0;
for (const [name, ok] of checks) {
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}`);
  if (!ok) failed++;
}
console.log(`\n${checks.length - failed}/${checks.length} checks passed`);
process.exitCode = failed ? 1 : 0;
