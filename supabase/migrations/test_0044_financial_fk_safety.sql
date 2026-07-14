-- ============================================================
-- Validation for 0044_financial_fk_safety.sql
-- Read-only metadata/data-quality checks. Safe for production.
-- Expected: every status = PASS and orphan counts = 0.
-- ============================================================

WITH expected(table_name, column_name) AS (
  VALUES
    ('escrow_records','order_id'),
    ('escrow_records','buyer_id'),
    ('escrow_records','seller_id'),
    ('refunds','order_id'),
    ('refunds','user_id'),
    ('disputes','order_id'),
    ('disputes','initiator_id')
), actual AS (
  SELECT c.relname AS table_name,
         a.attname AS column_name,
         con.confdeltype,
         con.convalidated
  FROM pg_constraint con
  JOIN pg_class c ON c.oid=con.conrelid
  JOIN pg_namespace n ON n.oid=c.relnamespace
  JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=ANY(con.conkey)
  WHERE con.contype='f' AND n.nspname='public' AND array_length(con.conkey,1)=1
)
SELECT e.table_name,
       e.column_name,
       CASE WHEN a.confdeltype='n' AND a.convalidated THEN 'PASS' ELSE 'FAIL' END AS set_null_fk_status
FROM expected e
LEFT JOIN actual a USING(table_name,column_name)
ORDER BY e.table_name,e.column_name;

SELECT table_name, column_name,
       CASE WHEN is_nullable='YES' THEN 'PASS' ELSE 'FAIL' END AS nullable_status
FROM information_schema.columns
WHERE table_schema='public'
  AND (table_name,column_name) IN (
    ('escrow_records','order_id'),('escrow_records','buyer_id'),('escrow_records','seller_id'),
    ('refunds','order_id'),('refunds','user_id'),
    ('disputes','order_id'),('disputes','initiator_id')
  )
ORDER BY table_name,column_name;

SELECT 'escrow_order_orphans' AS check_name, count(*) AS orphan_count
FROM public.escrow_records e LEFT JOIN public.orders o ON o.id=e.order_id
WHERE e.order_id IS NOT NULL AND o.id IS NULL
UNION ALL
SELECT 'refund_order_orphans', count(*)
FROM public.refunds r LEFT JOIN public.orders o ON o.id=r.order_id
WHERE r.order_id IS NOT NULL AND o.id IS NULL
UNION ALL
SELECT 'dispute_order_orphans', count(*)
FROM public.disputes d LEFT JOIN public.orders o ON o.id=d.order_id
WHERE d.order_id IS NOT NULL AND o.id IS NULL;

SELECT 'escrow_missing_snapshot' AS check_name, count(*) AS affected_rows
FROM public.escrow_records
WHERE order_id IS NOT NULL AND (
  order_no_snapshot IS NULL OR buyer_id_snapshot IS NULL OR seller_id_snapshot IS NULL OR
  total_amount_snapshot IS NULL OR payment_provider_snapshot IS NULL
)
UNION ALL
SELECT 'refund_missing_snapshot', count(*)
FROM public.refunds
WHERE order_id IS NOT NULL AND (
  order_no_snapshot IS NULL OR user_id_snapshot IS NULL OR refund_amount_snapshot IS NULL
)
UNION ALL
SELECT 'dispute_missing_snapshot', count(*)
FROM public.disputes
WHERE order_id IS NOT NULL AND (order_no_snapshot IS NULL OR initiator_id_snapshot IS NULL);

-- Human-readable summary
SELECT jsonb_build_object(
  'escrow_rows', (SELECT count(*) FROM public.escrow_records),
  'refund_rows', (SELECT count(*) FROM public.refunds),
  'dispute_rows', (SELECT count(*) FROM public.disputes),
  'escrow_detached_rows', (SELECT count(*) FROM public.escrow_records WHERE order_id IS NULL OR buyer_id IS NULL OR seller_id IS NULL),
  'refund_detached_rows', (SELECT count(*) FROM public.refunds WHERE order_id IS NULL OR user_id IS NULL),
  'dispute_detached_rows', (SELECT count(*) FROM public.disputes WHERE order_id IS NULL OR initiator_id IS NULL)
) AS sh006_phase1_summary;
