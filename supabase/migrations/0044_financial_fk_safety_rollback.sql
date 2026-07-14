-- ============================================================
-- Rollback for 0044_financial_fk_safety.sql
-- WARNING: rollback is intentionally fail-closed.
-- It refuses to restore NOT NULL/CASCADE if any parent references
-- have already been set to NULL after a deletion.
-- ============================================================

BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

DO $$
DECLARE
  v_null_count bigint;
BEGIN
  SELECT
    (SELECT count(*) FROM public.escrow_records WHERE order_id IS NULL OR buyer_id IS NULL OR seller_id IS NULL) +
    (SELECT count(*) FROM public.refunds WHERE order_id IS NULL OR user_id IS NULL) +
    (SELECT count(*) FROM public.disputes WHERE order_id IS NULL OR initiator_id IS NULL)
  INTO v_null_count;

  IF v_null_count > 0 THEN
    RAISE EXCEPTION '0044 rollback aborted: % rows contain NULL parent references. Restore parents manually before rollback.', v_null_count;
  END IF;
END $$;

ALTER TABLE public.escrow_records
  DROP CONSTRAINT IF EXISTS escrow_records_order_id_fkey,
  DROP CONSTRAINT IF EXISTS escrow_records_buyer_id_fkey,
  DROP CONSTRAINT IF EXISTS escrow_records_seller_id_fkey;

ALTER TABLE public.refunds
  DROP CONSTRAINT IF EXISTS refunds_order_id_fkey,
  DROP CONSTRAINT IF EXISTS refunds_user_id_fkey;

ALTER TABLE public.disputes
  DROP CONSTRAINT IF EXISTS disputes_order_id_fkey,
  DROP CONSTRAINT IF EXISTS disputes_initiator_id_fkey;

ALTER TABLE public.escrow_records
  ADD CONSTRAINT escrow_records_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
  ADD CONSTRAINT escrow_records_buyer_id_fkey FOREIGN KEY (buyer_id) REFERENCES auth.users(id) ON DELETE CASCADE,
  ADD CONSTRAINT escrow_records_seller_id_fkey FOREIGN KEY (seller_id) REFERENCES auth.users(id) ON DELETE CASCADE,
  ALTER COLUMN order_id SET NOT NULL,
  ALTER COLUMN buyer_id SET NOT NULL,
  ALTER COLUMN seller_id SET NOT NULL;

ALTER TABLE public.refunds
  ADD CONSTRAINT refunds_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
  ADD CONSTRAINT refunds_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL,
  ALTER COLUMN order_id SET NOT NULL,
  ALTER COLUMN user_id SET NOT NULL;

ALTER TABLE public.disputes
  ADD CONSTRAINT disputes_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
  ADD CONSTRAINT disputes_initiator_id_fkey FOREIGN KEY (initiator_id) REFERENCES auth.users(id) ON DELETE SET NULL,
  ALTER COLUMN order_id SET NOT NULL,
  ALTER COLUMN initiator_id SET NOT NULL;

ALTER TABLE public.escrow_records
  DROP COLUMN IF EXISTS order_no_snapshot,
  DROP COLUMN IF EXISTS buyer_id_snapshot,
  DROP COLUMN IF EXISTS seller_id_snapshot,
  DROP COLUMN IF EXISTS total_amount_snapshot,
  DROP COLUMN IF EXISTS payment_provider_snapshot;

ALTER TABLE public.refunds
  DROP COLUMN IF EXISTS order_no_snapshot,
  DROP COLUMN IF EXISTS user_id_snapshot,
  DROP COLUMN IF EXISTS refund_amount_snapshot;

ALTER TABLE public.disputes
  DROP COLUMN IF EXISTS order_no_snapshot,
  DROP COLUMN IF EXISTS initiator_id_snapshot;

COMMIT;
