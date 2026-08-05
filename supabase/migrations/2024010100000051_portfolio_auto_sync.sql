-- TASK-CR-0104-L: automatically sync new collections into portfolio assets.
-- Reuses sync_collections_to_portfolio(UUID); does not modify AI, payment or trading logic.

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.sync_collections_to_portfolio(uuid)') IS NULL THEN
    RAISE EXCEPTION '0051 requires public.sync_collections_to_portfolio(uuid)';
  END IF;
  IF to_regclass('public.user_collections') IS NULL
     OR to_regclass('public.portfolio_items') IS NULL
     OR to_regclass('public.user_portfolio') IS NULL THEN
    RAISE EXCEPTION '0051 requires user_collections, portfolio_items and user_portfolio';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_sync_collection_to_portfolio()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Serialize portfolio initialization per user so concurrent collection
  -- inserts cannot race through the idempotency check.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(NEW.user_id::text, 0)
  );

  -- An existing collection association or equivalent asset is authoritative.
  -- The task requires existing assets to be skipped, never overwritten.
  IF EXISTS (
    SELECT 1
    FROM public.portfolio_items AS pi
    WHERE pi.collection_id = NEW.id
       OR (
         pi.user_id = NEW.user_id
         AND pi.card_name = NEW.card_name
         AND pi.series = COALESCE(NEW.series, '')
         AND pi.rarity = COALESCE(NEW.rarity, 'N')
       )
  ) THEN
    RETURN NEW;
  END IF;

  -- Reuse the reviewed portfolio calculation and downstream aggregate trigger.
  PERFORM public.sync_collections_to_portfolio(NEW.user_id);

  -- Fail closed: a collection must not commit while its first asset silently
  -- disappears. Equivalent assets are accepted as the idempotent outcome.
  IF NOT EXISTS (
    SELECT 1
    FROM public.portfolio_items AS pi
    WHERE pi.collection_id = NEW.id
       OR (
         pi.user_id = NEW.user_id
         AND pi.card_name = NEW.card_name
         AND pi.series = COALESCE(NEW.series, '')
         AND pi.rarity = COALESCE(NEW.rarity, 'N')
       )
  ) THEN
    RAISE EXCEPTION '0051 portfolio auto-sync produced no asset for collection %', NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.auto_sync_collection_to_portfolio() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.auto_sync_collection_to_portfolio() FROM anon;
REVOKE ALL ON FUNCTION public.auto_sync_collection_to_portfolio() FROM authenticated;

DROP TRIGGER IF EXISTS trg_collection_auto_sync_portfolio ON public.user_collections;
CREATE TRIGGER trg_collection_auto_sync_portfolio
  AFTER INSERT ON public.user_collections
  FOR EACH ROW
  EXECUTE FUNCTION public.auto_sync_collection_to_portfolio();

COMMENT ON FUNCTION public.auto_sync_collection_to_portfolio() IS
  'CR-0104-L: idempotent trusted wrapper that syncs a new collection into portfolio assets.';
COMMENT ON TRIGGER trg_collection_auto_sync_portfolio ON public.user_collections IS
  'CR-0104-L: AFTER INSERT collection-to-portfolio synchronization.';

COMMIT;
