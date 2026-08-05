-- CR-0110-C / DH-1: portfolio_items identity orphan cleanup (MVP = ① + ② + ④).
-- Local-only until reviewed and deployed through an authorized channel (no db push yet).
--
-- Root cause (DH-1): sync_collections_to_portfolio() only upserts; it never removes
-- portfolio_items rows whose 8-col identity tuple no longer exists in user_collections.
-- Two orphan sources were uncovered:
--   Source A: user_collections row DELETEd entirely  -> no trigger fired (old trigger had no DELETE event)
--   Source B: identity column UPDATE (region/edition/product_code/packaging_type) -> old tuple orphan
--   Source C: historical orphans already present before this fix
--
-- This migration overlays the existing function (authoritative def in
-- 20260802113000_card_collection_quantity_upsert.sql) WITHOUT modifying that file:
--   ① sync_collections_to_portfolio(): append orphan DELETE after upsert
--   ② new AFTER DELETE trigger on user_collections -> re-sync owner (clears Source A)
--   ④ define cleanup_portfolio_orphans() for one-time historical backfill (NOT executed here)
--
-- Identity 8 columns (portfolio_items_identity_key):
--   user_id, card_name, series, rarity, product_code, region, edition, packaging_type
-- COALESCE map (MUST match GROUP BY / unique key / cleanup — single source of truth):
--   series->''  rarity->'N'  product_code->''  region->'UNKNOWN'  edition->'Unknown'  packaging_type->'card'
-- card_name and user_id are NOT coalesced (both NOT NULL).

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- ① sync_collections_to_portfolio(): identical upsert logic + orphan DELETE
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_collections_to_portfolio(p_user_id UUID DEFAULT NULL)
RETURNS TABLE(items_synced INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count INTEGER := 0;
  v_uid UUID;
BEGIN
  WITH totals AS (
    SELECT uc.user_id, uc.card_name, COALESCE(uc.series, '') AS series,
      COALESCE(uc.rarity, 'N') AS rarity, COALESCE(uc.product_code, '') AS product_code,
      COALESCE(uc.region, 'UNKNOWN') AS region, COALESCE(uc.edition, 'Unknown') AS edition,
      BOOL_OR(COALESCE(uc.is_first_edition, false)) AS is_first_edition,
      COALESCE(uc.packaging_type, 'card') AS packaging_type,
      (ARRAY_AGG(uc.id ORDER BY uc.created_at DESC NULLS LAST, uc.id DESC))[1] AS collection_id,
      (ARRAY_AGG(uc.card_image ORDER BY uc.created_at DESC NULLS LAST, uc.id DESC))[1] AS card_image,
      SUM(COALESCE(uc.quantity, 1))::INTEGER AS quantity,
      SUM(COALESCE(uc.purchase_price, 0) * COALESCE(uc.quantity, 1)) AS total_cost,
      COALESCE((ARRAY_AGG(uc.current_price ORDER BY uc.created_at DESC NULLS LAST, uc.id DESC)
        FILTER (WHERE uc.current_price IS NOT NULL))[1], 0) AS collection_price
    FROM public.user_collections AS uc
    WHERE p_user_id IS NULL OR uc.user_id = p_user_id
    GROUP BY uc.user_id, uc.card_name, COALESCE(uc.series, ''), COALESCE(uc.rarity, 'N'),
      COALESCE(uc.product_code, ''), COALESCE(uc.region, 'UNKNOWN'),
      COALESCE(uc.edition, 'Unknown'), COALESCE(uc.packaging_type, 'card')
  ), calculated AS (
    SELECT t.*, CASE WHEN t.quantity > 0 THEN t.total_cost / t.quantity ELSE 0 END AS avg_buy_price,
      COALESCE(m.final_price, t.collection_price, 0) AS current_price
    FROM totals AS t
    LEFT JOIN LATERAL (
      SELECT cm.final_price FROM public.card_market AS cm
      WHERE cm.card_name = t.card_name AND cm.series = t.series AND cm.rarity = t.rarity
        AND COALESCE(cm.product_code, '') = t.product_code
        AND COALESCE(cm.region, 'UNKNOWN') = t.region
        AND COALESCE(cm.edition, 'Unknown') = t.edition
      ORDER BY cm.updated_at DESC NULLS LAST, cm.id DESC LIMIT 1
    ) AS m ON TRUE
  )
  INSERT INTO public.portfolio_items (
    user_id, collection_id, card_name, series, rarity, card_image, quantity,
    avg_buy_price, total_cost, current_price, profit_loss, profit_percent,
    product_code, region, edition, is_first_edition, packaging_type
  )
  SELECT c.user_id, c.collection_id, c.card_name, c.series, c.rarity, c.card_image,
    c.quantity, c.avg_buy_price, c.total_cost, c.current_price,
    (c.current_price - c.avg_buy_price) * c.quantity,
    CASE WHEN c.avg_buy_price > 0 THEN ROUND((c.current_price-c.avg_buy_price)/c.avg_buy_price*100,2) ELSE 0 END,
    c.product_code, c.region, c.edition, c.is_first_edition, c.packaging_type
  FROM calculated AS c
  ON CONFLICT ON CONSTRAINT portfolio_items_identity_key DO UPDATE SET
    collection_id=EXCLUDED.collection_id, card_image=EXCLUDED.card_image,
    quantity=EXCLUDED.quantity, avg_buy_price=EXCLUDED.avg_buy_price,
    total_cost=EXCLUDED.total_cost, current_price=EXCLUDED.current_price,
    profit_loss=EXCLUDED.profit_loss, profit_percent=EXCLUDED.profit_percent,
    is_first_edition=EXCLUDED.is_first_edition, updated_at=NOW();
  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- [CR-0110-C / DH-1 ①] orphan DELETE: remove portfolio_items rows with no matching
  -- user_collections 8-col identity tuple. Uses the SAME COALESCE map as GROUP BY / unique key.
  -- pi.* already holds coalesced values (e.g. series=''), so compare COALESCE(uc.x)=pi.x.
  IF p_user_id IS NOT NULL THEN
    -- scoped: single DELETE, protected by the per-user advisory lock held by the caller trigger
    DELETE FROM public.portfolio_items AS pi
    WHERE pi.user_id = p_user_id
      AND NOT EXISTS (
        SELECT 1 FROM public.user_collections AS uc
        WHERE uc.user_id = p_user_id
          AND uc.card_name = pi.card_name
          AND COALESCE(uc.series, '') = pi.series
          AND COALESCE(uc.rarity, 'N') = pi.rarity
          AND COALESCE(uc.product_code, '') = pi.product_code
          AND COALESCE(uc.region, 'UNKNOWN') = pi.region
          AND COALESCE(uc.edition, 'Unknown') = pi.edition
          AND COALESCE(uc.packaging_type, 'card') = pi.packaging_type
      );
  ELSE
    -- full sync: loop per user, acquiring the same advisory lock, to avoid one long full-table lock
    FOR v_uid IN
      SELECT DISTINCT uc.user_id FROM public.user_collections AS uc ORDER BY uc.user_id
    LOOP
      PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(v_uid::text, 0));
      DELETE FROM public.portfolio_items AS pi
      WHERE pi.user_id = v_uid
        AND NOT EXISTS (
          SELECT 1 FROM public.user_collections AS uc
          WHERE uc.user_id = v_uid
            AND uc.card_name = pi.card_name
            AND COALESCE(uc.series, '') = pi.series
            AND COALESCE(uc.rarity, 'N') = pi.rarity
            AND COALESCE(uc.product_code, '') = pi.product_code
            AND COALESCE(uc.region, 'UNKNOWN') = pi.region
            AND COALESCE(uc.edition, 'Unknown') = pi.edition
            AND COALESCE(uc.packaging_type, 'card') = pi.packaging_type
        );
    END LOOP;
  END IF;

  items_synced := v_count; RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.sync_collections_to_portfolio(UUID) IS
  '从 user_collections 聚合持仓到 portfolio_items, upsert 后清理无对应 identity 元组的孤儿 [CR-0110-C / DH-1 ①]';

-- ─────────────────────────────────────────────────────────────────────────────
-- ② AFTER DELETE trigger on user_collections (clears Source A: delete whole row)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cleanup_portfolio_on_collection_delete()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  -- [CR-0110-C / DH-1 ②] a user_collections row was deleted. Re-sync that user so the
  -- orphan DELETE in ① removes the now-orphaned portfolio_items identity tuple.
  -- Acquire the same per-user advisory lock as the INSERT/UPDATE sync trigger to avoid
  -- concurrent-sync races; sync() is idempotent and only aggregates remaining rows.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(OLD.user_id::text, 0));
  PERFORM public.sync_collections_to_portfolio(OLD.user_id);
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_collection_delete_cleanup_portfolio ON public.user_collections;
CREATE TRIGGER trg_collection_delete_cleanup_portfolio
  AFTER DELETE ON public.user_collections FOR EACH ROW
  EXECUTE FUNCTION public.cleanup_portfolio_on_collection_delete();

-- ─────────────────────────────────────────────────────────────────────────────
-- ④ One-time historical orphan cleanup (Source C). DEFINED ONLY — NOT executed by
--    this migration (prohibited). Run post-deploy in a low-traffic window as service_role:
--      SELECT * FROM public.cleanup_portfolio_orphans();
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cleanup_portfolio_orphans()
RETURNS TABLE(orphans_removed INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_del INTEGER := 0;
BEGIN
  DELETE FROM public.portfolio_items AS pi
  WHERE NOT EXISTS (
    SELECT 1 FROM public.user_collections AS uc
    WHERE uc.user_id = pi.user_id
      AND uc.card_name = pi.card_name
      AND COALESCE(uc.series, '') = pi.series
      AND COALESCE(uc.rarity, 'N') = pi.rarity
      AND COALESCE(uc.product_code, '') = pi.product_code
      AND COALESCE(uc.region, 'UNKNOWN') = pi.region
      AND COALESCE(uc.edition, 'Unknown') = pi.edition
      AND COALESCE(uc.packaging_type, 'card') = pi.packaging_type
  );
  GET DIAGNOSTICS v_del = ROW_COUNT;
  orphans_removed := v_del; RETURN NEXT;
END;
$$;

-- Restrict the two new/maintenance functions: trigger fn runs as SECURITY DEFINER owner;
-- cleanup_portfolio_orphans() is ops-only (service_role). Neither callable by anon/authenticated.
REVOKE ALL ON FUNCTION public.cleanup_portfolio_on_collection_delete() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cleanup_portfolio_orphans() FROM PUBLIC, anon, authenticated;

COMMIT;
