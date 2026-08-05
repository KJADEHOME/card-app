-- TASK-CR-0104-N: make collection-to-portfolio synchronization idempotent.
-- Scope: portfolio synchronization only. No data rows are deleted.

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.sync_collections_to_portfolio(uuid)') IS NULL THEN
    RAISE EXCEPTION '0052 requires public.sync_collections_to_portfolio(uuid)';
  END IF;
  IF to_regprocedure('public.auto_sync_collection_to_portfolio()') IS NULL THEN
    RAISE EXCEPTION '0052 requires public.auto_sync_collection_to_portfolio()';
  END IF;
  IF to_regclass('public.user_collections') IS NULL
     OR to_regclass('public.portfolio_items') IS NULL
     OR to_regclass('public.user_portfolio') IS NULL THEN
    RAISE EXCEPTION '0052 requires user_collections, portfolio_items and user_portfolio';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_collections_to_portfolio(
  p_user_id UUID DEFAULT NULL
) RETURNS TABLE(items_synced INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  WITH collection_totals AS (
    SELECT
      uc.user_id,
      uc.card_name,
      COALESCE(uc.series, '') AS series,
      COALESCE(uc.rarity, 'N') AS rarity,
      (ARRAY_AGG(uc.id ORDER BY uc.created_at DESC NULLS LAST, uc.id DESC))[1]
        AS collection_id,
      (ARRAY_AGG(uc.card_image ORDER BY uc.created_at DESC NULLS LAST, uc.id DESC))[1]
        AS card_image,
      SUM(COALESCE(uc.quantity, 1))::INTEGER AS quantity,
      SUM(COALESCE(uc.purchase_price, 0) * COALESCE(uc.quantity, 1)) AS total_cost,
      COALESCE(
        (ARRAY_AGG(uc.current_price ORDER BY uc.created_at DESC NULLS LAST, uc.id DESC)
          FILTER (WHERE uc.current_price IS NOT NULL))[1],
        0
      ) AS collection_price
    FROM public.user_collections AS uc
    WHERE p_user_id IS NULL OR uc.user_id = p_user_id
    GROUP BY
      uc.user_id,
      uc.card_name,
      COALESCE(uc.series, ''),
      COALESCE(uc.rarity, 'N')
  ), calculated AS (
    SELECT
      ct.*,
      CASE WHEN ct.quantity > 0
        THEN ct.total_cost / ct.quantity
        ELSE 0
      END AS avg_buy_price,
      COALESCE(market.final_price, ct.collection_price, 0) AS current_price
    FROM collection_totals AS ct
    LEFT JOIN LATERAL (
      SELECT cm.final_price
      FROM public.card_market AS cm
      WHERE cm.card_name = ct.card_name
        AND cm.series = ct.series
        AND cm.rarity = ct.rarity
        AND cm.market = 'CN'
      ORDER BY cm.updated_at DESC NULLS LAST, cm.id DESC
      LIMIT 1
    ) AS market ON TRUE
  )
  INSERT INTO public.portfolio_items (
    user_id, collection_id, card_name, series, rarity, card_image,
    quantity, avg_buy_price, total_cost, current_price,
    profit_loss, profit_percent
  )
  SELECT
    c.user_id,
    c.collection_id,
    c.card_name,
    c.series,
    c.rarity,
    c.card_image,
    c.quantity,
    c.avg_buy_price,
    c.total_cost,
    c.current_price,
    (c.current_price - c.avg_buy_price) * c.quantity,
    CASE WHEN c.avg_buy_price > 0
      THEN ROUND((c.current_price - c.avg_buy_price) / c.avg_buy_price * 100, 2)
      ELSE 0
    END
  FROM calculated AS c
  ON CONFLICT (user_id, card_name, series, rarity)
  DO UPDATE SET
    collection_id = EXCLUDED.collection_id,
    card_image = EXCLUDED.card_image,
    quantity = EXCLUDED.quantity,
    avg_buy_price = EXCLUDED.avg_buy_price,
    total_cost = EXCLUDED.total_cost,
    current_price = EXCLUDED.current_price,
    profit_loss = EXCLUDED.profit_loss,
    profit_percent = EXCLUDED.profit_percent,
    updated_at = NOW();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  items_synced := v_count;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_sync_collection_to_portfolio()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(NEW.user_id::text, 0)
  );

  PERFORM public.sync_collections_to_portfolio(NEW.user_id);

  IF NOT EXISTS (
    SELECT 1
    FROM public.portfolio_items AS pi
    WHERE pi.user_id = NEW.user_id
      AND pi.card_name = NEW.card_name
      AND pi.series = COALESCE(NEW.series, '')
      AND pi.rarity = COALESCE(NEW.rarity, 'N')
      AND pi.quantity = (
        SELECT SUM(COALESCE(uc.quantity, 1))::INTEGER
        FROM public.user_collections AS uc
        WHERE uc.user_id = NEW.user_id
          AND uc.card_name = NEW.card_name
          AND COALESCE(uc.series, '') = COALESCE(NEW.series, '')
          AND COALESCE(uc.rarity, 'N') = COALESCE(NEW.rarity, 'N')
      )
  ) THEN
    RAISE EXCEPTION '0052 portfolio auto-sync failed for collection %', NEW.id;
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

COMMENT ON FUNCTION public.sync_collections_to_portfolio(UUID) IS
  'CR-0104-N: aggregate collections by user/card/series/rarity and upsert portfolio items.';
COMMENT ON FUNCTION public.auto_sync_collection_to_portfolio() IS
  'CR-0104-N: AFTER INSERT portfolio sync with aggregate quantity verification.';
COMMENT ON TRIGGER trg_collection_auto_sync_portfolio ON public.user_collections IS
  'CR-0104-N: AFTER INSERT collection-to-portfolio synchronization.';

COMMIT;
