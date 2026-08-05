-- TASK-CR-0105-E: verification outcome metadata for payment callback evidence.
-- Provider cryptography remains in the trusted verification service.
-- This migration does not modify public.process_payment_success().

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.payment_callbacks') IS NULL THEN
    RAISE EXCEPTION '0060 requires public.payment_callbacks from 0059';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'payment_callbacks'
      AND column_name = 'failed_reason'
  ) THEN
    RAISE EXCEPTION '0060 expected payment_callbacks.failed_reason to be absent';
  END IF;
END;
$$;

ALTER TABLE public.payment_callbacks
  ADD COLUMN failed_reason TEXT;

ALTER TABLE public.payment_callbacks
  ADD CONSTRAINT payment_callbacks_failed_reason_check
  CHECK (
    (verify_status = 'rejected' AND length(btrim(failed_reason)) > 0)
    OR (verify_status <> 'rejected' AND failed_reason IS NULL)
  );

CREATE OR REPLACE FUNCTION public.protect_payment_callback_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.provider IS DISTINCT FROM OLD.provider
     OR NEW.trade_no IS DISTINCT FROM OLD.trade_no
     OR NEW.payment_no IS DISTINCT FROM OLD.payment_no
     OR NEW.order_id IS DISTINCT FROM OLD.order_id
     OR NEW.amount IS DISTINCT FROM OLD.amount
     OR NEW.currency IS DISTINCT FROM OLD.currency
     OR NEW.raw_payload IS DISTINCT FROM OLD.raw_payload
     OR NEW.signature IS DISTINCT FROM OLD.signature
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'payment callback evidence is immutable'
      USING ERRCODE = 'P0001';
  END IF;

  IF OLD.verify_status IN ('verified', 'rejected')
     AND (
       NEW.verify_status IS DISTINCT FROM OLD.verify_status
       OR NEW.verified_at IS DISTINCT FROM OLD.verified_at
       OR NEW.failed_reason IS DISTINCT FROM OLD.failed_reason
     ) THEN
    RAISE EXCEPTION 'payment callback verification result is terminal'
      USING ERRCODE = 'P0001';
  END IF;

  IF OLD.callback_status = 'processed'
     AND NEW.callback_status IS DISTINCT FROM OLD.callback_status THEN
    RAISE EXCEPTION 'processed payment callback status is terminal'
      USING ERRCODE = 'P0001';
  END IF;

  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$;

COMMENT ON COLUMN public.payment_callbacks.failed_reason IS
  'Stable, non-secret verification failure reason set by the trusted verification service.';

COMMIT;
