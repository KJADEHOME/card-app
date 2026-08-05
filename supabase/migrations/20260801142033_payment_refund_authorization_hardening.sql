-- CR-0106 payment pre-revenue hardening.
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.escrow_refund_to_buyer(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'payment refund hardening requires escrow_refund_to_buyer(uuid,text)';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.escrow_refund_to_buyer(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.escrow_refund_to_buyer(UUID, TEXT)
  TO service_role;

COMMENT ON FUNCTION public.escrow_refund_to_buyer(UUID, TEXT) IS
  'Internal-only refund settlement. Provider refunds require confirmed, idempotent provider processing before this RPC is called.';

COMMIT;