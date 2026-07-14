-- ============================================================
-- 0044: SH-006 Phase 1 — Financial Foreign-Key Safety
-- Purpose:
--   Preserve escrow/refund/dispute history when users or orders
--   are deleted. Replace destructive ON DELETE CASCADE behavior
--   with ON DELETE SET NULL and retain immutable identity snapshots.
--
-- Safe to re-run: no (standard migration). Run once.
-- Rollback: see 0044_financial_fk_safety_rollback.sql
-- ============================================================

BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ------------------------------------------------------------
-- 0. Pre-flight: fail closed if required tables/columns are absent
-- ------------------------------------------------------------
DO $$
DECLARE
  v_missing text[] := ARRAY[]::text[];
BEGIN
  IF to_regclass('public.escrow_records') IS NULL THEN
    v_missing := array_append(v_missing, 'public.escrow_records');
  END IF;
  IF to_regclass('public.refunds') IS NULL THEN
    v_missing := array_append(v_missing, 'public.refunds');
  END IF;
  IF to_regclass('public.disputes') IS NULL THEN
    v_missing := array_append(v_missing, 'public.disputes');
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    v_missing := array_append(v_missing, 'public.orders');
  END IF;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION '0044 pre-flight failed. Missing relations: %', array_to_string(v_missing, ', ');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='escrow_records' AND column_name='order_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='escrow_records' AND column_name='buyer_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='escrow_records' AND column_name='seller_id'
  ) THEN
    RAISE EXCEPTION '0044 pre-flight failed: escrow_records required FK columns are missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='refunds' AND column_name='order_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='refunds' AND column_name='user_id'
  ) THEN
    RAISE EXCEPTION '0044 pre-flight failed: refunds required FK columns are missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='disputes' AND column_name='order_id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='disputes' AND column_name='initiator_id'
  ) THEN
    RAISE EXCEPTION '0044 pre-flight failed: disputes required FK columns are missing';
  END IF;
END $$;

-- ------------------------------------------------------------
-- 1. Add immutable historical snapshot fields
-- ------------------------------------------------------------
ALTER TABLE public.escrow_records
  ADD COLUMN IF NOT EXISTS order_no_snapshot text,
  ADD COLUMN IF NOT EXISTS buyer_id_snapshot uuid,
  ADD COLUMN IF NOT EXISTS seller_id_snapshot uuid,
  ADD COLUMN IF NOT EXISTS total_amount_snapshot numeric(12,2),
  ADD COLUMN IF NOT EXISTS payment_provider_snapshot text;

ALTER TABLE public.refunds
  ADD COLUMN IF NOT EXISTS order_no_snapshot text,
  ADD COLUMN IF NOT EXISTS user_id_snapshot uuid,
  ADD COLUMN IF NOT EXISTS refund_amount_snapshot numeric(12,2);

ALTER TABLE public.disputes
  ADD COLUMN IF NOT EXISTS order_no_snapshot text,
  ADD COLUMN IF NOT EXISTS initiator_id_snapshot uuid;

-- Backfill once. COALESCE preserves any pre-existing immutable snapshots.
UPDATE public.escrow_records e
SET
  order_no_snapshot = COALESCE(e.order_no_snapshot, o.order_no),
  buyer_id_snapshot = COALESCE(e.buyer_id_snapshot, e.buyer_id),
  seller_id_snapshot = COALESCE(e.seller_id_snapshot, e.seller_id),
  total_amount_snapshot = COALESCE(e.total_amount_snapshot, e.total_amount),
  payment_provider_snapshot = COALESCE(e.payment_provider_snapshot, e.payment_provider)
FROM public.orders o
WHERE o.id = e.order_id
  AND (
    e.order_no_snapshot IS NULL OR
    e.buyer_id_snapshot IS NULL OR
    e.seller_id_snapshot IS NULL OR
    e.total_amount_snapshot IS NULL OR
    e.payment_provider_snapshot IS NULL
  );

-- Handle escrow rows whose order is already absent (defensive).
UPDATE public.escrow_records
SET
  buyer_id_snapshot = COALESCE(buyer_id_snapshot, buyer_id),
  seller_id_snapshot = COALESCE(seller_id_snapshot, seller_id),
  total_amount_snapshot = COALESCE(total_amount_snapshot, total_amount),
  payment_provider_snapshot = COALESCE(payment_provider_snapshot, payment_provider)
WHERE buyer_id_snapshot IS NULL
   OR seller_id_snapshot IS NULL
   OR total_amount_snapshot IS NULL
   OR payment_provider_snapshot IS NULL;

UPDATE public.refunds r
SET
  order_no_snapshot = COALESCE(r.order_no_snapshot, o.order_no),
  user_id_snapshot = COALESCE(r.user_id_snapshot, r.user_id),
  refund_amount_snapshot = COALESCE(r.refund_amount_snapshot, r.refund_amount)
FROM public.orders o
WHERE o.id = r.order_id
  AND (
    r.order_no_snapshot IS NULL OR
    r.user_id_snapshot IS NULL OR
    r.refund_amount_snapshot IS NULL
  );

UPDATE public.refunds
SET
  user_id_snapshot = COALESCE(user_id_snapshot, user_id),
  refund_amount_snapshot = COALESCE(refund_amount_snapshot, refund_amount)
WHERE user_id_snapshot IS NULL OR refund_amount_snapshot IS NULL;

UPDATE public.disputes d
SET
  order_no_snapshot = COALESCE(d.order_no_snapshot, o.order_no),
  initiator_id_snapshot = COALESCE(d.initiator_id_snapshot, d.initiator_id)
FROM public.orders o
WHERE o.id = d.order_id
  AND (d.order_no_snapshot IS NULL OR d.initiator_id_snapshot IS NULL);

UPDATE public.disputes
SET initiator_id_snapshot = COALESCE(initiator_id_snapshot, initiator_id)
WHERE initiator_id_snapshot IS NULL;

-- ------------------------------------------------------------
-- 2. Columns must allow NULL for ON DELETE SET NULL to work
-- ------------------------------------------------------------
ALTER TABLE public.escrow_records
  ALTER COLUMN order_id DROP NOT NULL,
  ALTER COLUMN buyer_id DROP NOT NULL,
  ALTER COLUMN seller_id DROP NOT NULL;

ALTER TABLE public.refunds
  ALTER COLUMN order_id DROP NOT NULL,
  ALTER COLUMN user_id DROP NOT NULL;

ALTER TABLE public.disputes
  ALTER COLUMN order_id DROP NOT NULL,
  ALTER COLUMN initiator_id DROP NOT NULL;

-- ------------------------------------------------------------
-- 3. Replace existing single-column FK constraints safely.
--    Constraint names may differ across environments, so discover
--    them by table+column rather than assuming generated names.
-- ------------------------------------------------------------
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT n.nspname AS schema_name, c.relname AS table_name, con.conname
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(con.conkey)
    WHERE con.contype = 'f'
      AND n.nspname = 'public'
      AND (
        (c.relname='escrow_records' AND a.attname IN ('order_id','buyer_id','seller_id')) OR
        (c.relname='refunds' AND a.attname IN ('order_id','user_id')) OR
        (c.relname='disputes' AND a.attname IN ('order_id','initiator_id'))
      )
      AND array_length(con.conkey, 1) = 1
  LOOP
    EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I', r.schema_name, r.table_name, r.conname);
  END LOOP;
END $$;

ALTER TABLE public.escrow_records
  ADD CONSTRAINT escrow_records_order_id_fkey
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL NOT VALID,
  ADD CONSTRAINT escrow_records_buyer_id_fkey
    FOREIGN KEY (buyer_id) REFERENCES auth.users(id) ON DELETE SET NULL NOT VALID,
  ADD CONSTRAINT escrow_records_seller_id_fkey
    FOREIGN KEY (seller_id) REFERENCES auth.users(id) ON DELETE SET NULL NOT VALID;

ALTER TABLE public.refunds
  ADD CONSTRAINT refunds_order_id_fkey
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL NOT VALID,
  ADD CONSTRAINT refunds_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL NOT VALID;

ALTER TABLE public.disputes
  ADD CONSTRAINT disputes_order_id_fkey
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL NOT VALID,
  ADD CONSTRAINT disputes_initiator_id_fkey
    FOREIGN KEY (initiator_id) REFERENCES auth.users(id) ON DELETE SET NULL NOT VALID;

-- Validate separately after short metadata locks have been released.
ALTER TABLE public.escrow_records VALIDATE CONSTRAINT escrow_records_order_id_fkey;
ALTER TABLE public.escrow_records VALIDATE CONSTRAINT escrow_records_buyer_id_fkey;
ALTER TABLE public.escrow_records VALIDATE CONSTRAINT escrow_records_seller_id_fkey;
ALTER TABLE public.refunds VALIDATE CONSTRAINT refunds_order_id_fkey;
ALTER TABLE public.refunds VALIDATE CONSTRAINT refunds_user_id_fkey;
ALTER TABLE public.disputes VALIDATE CONSTRAINT disputes_order_id_fkey;
ALTER TABLE public.disputes VALIDATE CONSTRAINT disputes_initiator_id_fkey;

COMMENT ON COLUMN public.escrow_records.order_no_snapshot IS 'Immutable order number retained if parent order is deleted';
COMMENT ON COLUMN public.escrow_records.buyer_id_snapshot IS 'Original buyer UUID retained for audit/history';
COMMENT ON COLUMN public.escrow_records.seller_id_snapshot IS 'Original seller UUID retained for audit/history';
COMMENT ON COLUMN public.refunds.order_no_snapshot IS 'Immutable order number retained if parent order is deleted';
COMMENT ON COLUMN public.disputes.order_no_snapshot IS 'Immutable order number retained if parent order is deleted';

COMMIT;
