-- TASK-CR-0105-D: trusted payment callback evidence layer.
-- This migration does not integrate a provider and does not modify process_payment_success().

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.payment_callbacks') IS NOT NULL THEN
    RAISE EXCEPTION '0059 expected public.payment_callbacks to be absent';
  END IF;
  IF to_regclass('public.payment_orders') IS NULL
     OR to_regclass('public.orders') IS NULL THEN
    RAISE EXCEPTION '0059 requires public.payment_orders and public.orders';
  END IF;
  IF to_regprocedure('public.protect_payment_callback_audit()') IS NOT NULL THEN
    RAISE EXCEPTION '0059 expected public.protect_payment_callback_audit() to be absent';
  END IF;
END;
$$;

CREATE TABLE public.payment_callbacks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider TEXT NOT NULL,
  trade_no TEXT NOT NULL,
  payment_no TEXT NOT NULL,
  order_id UUID,
  amount NUMERIC(12,2) NOT NULL,
  currency TEXT NOT NULL DEFAULT 'CNY',
  raw_payload JSONB NOT NULL,
  signature TEXT NOT NULL,
  verify_status TEXT NOT NULL DEFAULT 'received',
  callback_status TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  verified_at TIMESTAMPTZ,
  processed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT payment_callbacks_provider_check
    CHECK (provider IN ('alipay', 'wechat')),
  CONSTRAINT payment_callbacks_trade_no_check
    CHECK (length(btrim(trade_no)) > 0),
  CONSTRAINT payment_callbacks_payment_no_check
    CHECK (length(btrim(payment_no)) > 0),
  CONSTRAINT payment_callbacks_amount_check
    CHECK (amount > 0),
  CONSTRAINT payment_callbacks_currency_check
    CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT payment_callbacks_signature_check
    CHECK (length(btrim(signature)) > 0),
  CONSTRAINT payment_callbacks_verify_status_check
    CHECK (verify_status IN ('received', 'verified', 'rejected')),
  CONSTRAINT payment_callbacks_callback_status_check
    CHECK (callback_status IN ('pending', 'processing', 'processed', 'failed')),
  CONSTRAINT payment_callbacks_verified_at_check
    CHECK (
      (verify_status = 'verified' AND verified_at IS NOT NULL)
      OR (verify_status <> 'verified' AND verified_at IS NULL)
    ),
  CONSTRAINT payment_callbacks_processed_at_check
    CHECK (
      (callback_status = 'processed' AND processed_at IS NOT NULL AND verify_status = 'verified')
      OR (callback_status <> 'processed' AND processed_at IS NULL)
    ),
  CONSTRAINT payment_callbacks_payment_no_fkey
    FOREIGN KEY (payment_no)
    REFERENCES public.payment_orders(payment_no)
    ON UPDATE RESTRICT
    ON DELETE RESTRICT,
  CONSTRAINT payment_callbacks_order_id_fkey
    FOREIGN KEY (order_id)
    REFERENCES public.orders(id)
    ON UPDATE RESTRICT
    ON DELETE SET NULL,
  CONSTRAINT payment_callbacks_provider_trade_no_key
    UNIQUE (provider, trade_no)
);

CREATE INDEX payment_callbacks_payment_no_idx
  ON public.payment_callbacks(payment_no);
CREATE INDEX payment_callbacks_order_id_idx
  ON public.payment_callbacks(order_id)
  WHERE order_id IS NOT NULL;
CREATE INDEX payment_callbacks_status_idx
  ON public.payment_callbacks(verify_status, callback_status, created_at);
CREATE INDEX payment_callbacks_created_at_idx
  ON public.payment_callbacks(created_at DESC);

CREATE FUNCTION public.protect_payment_callback_audit()
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
     AND NEW.verify_status IS DISTINCT FROM OLD.verify_status THEN
    RAISE EXCEPTION 'payment callback verification status is terminal'
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

CREATE TRIGGER protect_payment_callback_audit_trigger
  BEFORE UPDATE ON public.payment_callbacks
  FOR EACH ROW
  EXECUTE FUNCTION public.protect_payment_callback_audit();

ALTER TABLE public.payment_callbacks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_callbacks FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.payment_callbacks FROM PUBLIC;
REVOKE ALL ON TABLE public.payment_callbacks FROM anon;
REVOKE ALL ON TABLE public.payment_callbacks FROM authenticated;
REVOKE ALL ON TABLE public.payment_callbacks FROM service_role;
GRANT SELECT, INSERT, UPDATE ON TABLE public.payment_callbacks TO service_role;

REVOKE ALL ON FUNCTION public.protect_payment_callback_audit() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.protect_payment_callback_audit() FROM anon;
REVOKE ALL ON FUNCTION public.protect_payment_callback_audit() FROM authenticated;

COMMENT ON TABLE public.payment_callbacks IS
  'CR-0105-D: append-oriented evidence and processing state for verified provider callbacks; client access denied.';
COMMENT ON COLUMN public.payment_callbacks.provider IS
  'Payment provider namespace; currently alipay or wechat.';
COMMENT ON COLUMN public.payment_callbacks.trade_no IS
  'Provider transaction identifier; unique within provider for callback idempotency.';
COMMENT ON COLUMN public.payment_callbacks.raw_payload IS
  'Untrusted callback evidence. Authenticity must be established outside this migration.';
COMMENT ON COLUMN public.payment_callbacks.signature IS
  'Provider signature evidence. This database layer does not verify it.';
COMMENT ON COLUMN public.payment_callbacks.verify_status IS
  'Verification result controlled by a future trusted webhook layer.';
COMMENT ON COLUMN public.payment_callbacks.callback_status IS
  'Internal processing state; this migration does not settle payments.';

COMMIT;
