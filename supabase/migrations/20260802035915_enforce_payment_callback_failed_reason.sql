-- CR-0105-E follow-up: PostgreSQL CHECK constraints accept UNKNOWN, so the
-- original `length(btrim(failed_reason)) > 0` predicate allowed NULL for a
-- rejected callback. Normalize legacy rows, then require a non-NULL reason.

UPDATE public.payment_callbacks
SET failed_reason = 'LEGACY_MISSING_FAILED_REASON'
WHERE verify_status = 'rejected'
  AND (failed_reason IS NULL OR length(btrim(failed_reason)) = 0);

ALTER TABLE public.payment_callbacks
  DROP CONSTRAINT IF EXISTS payment_callbacks_failed_reason_check;

ALTER TABLE public.payment_callbacks
  ADD CONSTRAINT payment_callbacks_failed_reason_check
  CHECK (
    (verify_status = 'rejected'
      AND failed_reason IS NOT NULL
      AND length(btrim(failed_reason)) > 0)
    OR (verify_status <> 'rejected' AND failed_reason IS NULL)
  );

COMMENT ON CONSTRAINT payment_callbacks_failed_reason_check
  ON public.payment_callbacks IS
  'Rejected callbacks require a non-null, non-blank stable failure reason; all other states require NULL.';
