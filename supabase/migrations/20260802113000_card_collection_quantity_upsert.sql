-- AI scan quantity intake and region-aware portfolio aggregation.
-- Local-only until reviewed and deployed through an authorized channel.

BEGIN;

ALTER TABLE public.user_collections
  ADD COLUMN IF NOT EXISTS product_code TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS region TEXT NOT NULL DEFAULT 'UNKNOWN'
    CHECK (region IN ('JP', 'KR', 'CN', 'US', 'UNKNOWN')),
  ADD COLUMN IF NOT EXISTS edition TEXT NOT NULL DEFAULT 'Unknown',
  ADD COLUMN IF NOT EXISTS is_first_edition BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS packaging_type TEXT NOT NULL DEFAULT 'card'
    CHECK (packaging_type IN ('card', 'slab', 'box', 'carton'));

ALTER TABLE public.portfolio_items
  ADD COLUMN IF NOT EXISTS product_code TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS region TEXT NOT NULL DEFAULT 'UNKNOWN'
    CHECK (region IN ('JP', 'KR', 'CN', 'US', 'UNKNOWN')),
  ADD COLUMN IF NOT EXISTS edition TEXT NOT NULL DEFAULT 'Unknown',
  ADD COLUMN IF NOT EXISTS is_first_edition BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS packaging_type TEXT NOT NULL DEFAULT 'card'
    CHECK (packaging_type IN ('card', 'slab', 'box', 'carton'));

ALTER TABLE public.portfolio_items
  DROP CONSTRAINT IF EXISTS portfolio_items_user_id_card_name_series_rarity_key;
ALTER TABLE public.portfolio_items
  ADD CONSTRAINT portfolio_items_identity_key UNIQUE
    (user_id, card_name, series, rarity, product_code, region, edition, packaging_type);

CREATE OR REPLACE FUNCTION public.sync_collections_to_portfolio(p_user_id UUID DEFAULT NULL)
RETURNS TABLE(items_synced INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_count INTEGER := 0;
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
  items_synced := v_count; RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_sync_collection_to_portfolio()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(NEW.user_id::text, 0));
  PERFORM public.sync_collections_to_portfolio(NEW.user_id);
  IF NOT EXISTS (
    SELECT 1 FROM public.portfolio_items AS pi
    WHERE pi.user_id=NEW.user_id AND pi.card_name=NEW.card_name
      AND pi.series=COALESCE(NEW.series,'') AND pi.rarity=COALESCE(NEW.rarity,'N')
      AND pi.product_code=COALESCE(NEW.product_code,'') AND pi.region=COALESCE(NEW.region,'UNKNOWN')
      AND pi.edition=COALESCE(NEW.edition,'Unknown') AND pi.packaging_type=COALESCE(NEW.packaging_type,'card')
      AND pi.quantity=(SELECT SUM(COALESCE(uc.quantity,1))::INTEGER FROM public.user_collections AS uc
  IF TG_OP = 'UPDATE' AND ROW(OLD.product_code, OLD.region, OLD.edition, OLD.packaging_type)
      IS DISTINCT FROM ROW(NEW.product_code, NEW.region, NEW.edition, NEW.packaging_type) THEN
    DELETE FROM public.portfolio_items AS pi
    WHERE pi.user_id=OLD.user_id AND pi.card_name=OLD.card_name
      AND pi.series=COALESCE(OLD.series,'') AND pi.rarity=COALESCE(OLD.rarity,'N')
      AND pi.product_code=COALESCE(OLD.product_code,'') AND pi.region=COALESCE(OLD.region,'UNKNOWN')
      AND pi.edition=COALESCE(OLD.edition,'Unknown') AND pi.packaging_type=COALESCE(OLD.packaging_type,'card')
      AND NOT EXISTS (
        SELECT 1 FROM public.user_collections AS uc
        WHERE uc.user_id=OLD.user_id AND uc.card_name=OLD.card_name
          AND COALESCE(uc.series,'')=COALESCE(OLD.series,'')
          AND COALESCE(uc.rarity,'N')=COALESCE(OLD.rarity,'N')
          AND COALESCE(uc.product_code,'')=COALESCE(OLD.product_code,'')
          AND COALESCE(uc.region,'UNKNOWN')=COALESCE(OLD.region,'UNKNOWN')
          AND COALESCE(uc.edition,'Unknown')=COALESCE(OLD.edition,'Unknown')
          AND COALESCE(uc.packaging_type,'card')=COALESCE(OLD.packaging_type,'card')
      );
  END IF;
        WHERE uc.user_id=NEW.user_id AND uc.card_name=NEW.card_name
          AND COALESCE(uc.series,'')=COALESCE(NEW.series,'') AND COALESCE(uc.rarity,'N')=COALESCE(NEW.rarity,'N')
          AND COALESCE(uc.product_code,'')=COALESCE(NEW.product_code,'') AND COALESCE(uc.region,'UNKNOWN')=COALESCE(NEW.region,'UNKNOWN')
          AND COALESCE(uc.edition,'Unknown')=COALESCE(NEW.edition,'Unknown') AND COALESCE(uc.packaging_type,'card')=COALESCE(NEW.packaging_type,'card'))
  ) THEN RAISE EXCEPTION 'portfolio quantity sync failed for collection %', NEW.id; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_collection_auto_sync_portfolio ON public.user_collections;
CREATE TRIGGER trg_collection_auto_sync_portfolio
AFTER INSERT OR UPDATE OF quantity, purchase_price, current_price, product_code, region, edition, packaging_type
ON public.user_collections FOR EACH ROW EXECUTE FUNCTION public.auto_sync_collection_to_portfolio();

CREATE OR REPLACE FUNCTION public.complete_card_entry_with_quantity(
  p_user_id UUID, p_card_name TEXT, p_series TEXT DEFAULT '', p_rarity TEXT DEFAULT 'N',
  p_card_image TEXT DEFAULT NULL, p_purchase_price NUMERIC(12,2) DEFAULT 0,
  p_current_price NUMERIC(12,2) DEFAULT 0, p_card_category TEXT DEFAULT 'other',
  p_source TEXT DEFAULT 'AI_SCAN', p_scan_type TEXT DEFAULT 'camera', p_image_hash TEXT DEFAULT NULL,
  p_card_type TEXT DEFAULT NULL, p_game TEXT DEFAULT NULL, p_confidence NUMERIC(3,2) DEFAULT 0,
  p_suggested_cards JSONB DEFAULT '[]'::jsonb, p_ai_reason TEXT DEFAULT NULL,
  p_ai_failed BOOLEAN DEFAULT FALSE, p_quantity INTEGER DEFAULT 1, p_product_code TEXT DEFAULT '',
  p_region TEXT DEFAULT 'UNKNOWN', p_edition TEXT DEFAULT 'Unknown',
  p_is_first_edition BOOLEAN DEFAULT FALSE, p_packaging_type TEXT DEFAULT 'card'
) RETURNS TABLE(success BOOLEAN, collection_id UUID, scan_history_id UUID, scan_log_id UUID,
  points_cost INTEGER, points_discounted INTEGER, error TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v RECORD;
BEGIN
  IF (SELECT auth.uid()) IS NULL OR (SELECT auth.uid()) <> p_user_id THEN
    RAISE EXCEPTION 'authenticated user mismatch' USING ERRCODE='42501';
  END IF;
  IF p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 1000 THEN
    RAISE EXCEPTION 'quantity must be between 1 and 1000' USING ERRCODE='22023';
  END IF;
  IF p_region NOT IN ('JP','KR','CN','US','UNKNOWN') THEN RAISE EXCEPTION 'invalid region' USING ERRCODE='22023'; END IF;
  IF p_packaging_type NOT IN ('card','slab','box','carton') THEN RAISE EXCEPTION 'invalid packaging type' USING ERRCODE='22023'; END IF;

  SELECT * INTO v FROM public.complete_card_entry(p_user_id, p_card_name, p_series, p_rarity,
    p_card_image, p_purchase_price, p_current_price, p_card_category, p_source, p_scan_type,
    p_image_hash, p_card_type, p_game, p_confidence, p_suggested_cards, p_ai_reason, p_ai_failed);
  IF v.success THEN
    UPDATE public.user_collections SET quantity=p_quantity, product_code=COALESCE(p_product_code,''),
      region=p_region, edition=COALESCE(NULLIF(p_edition,''),'Unknown'),
      is_first_edition=p_is_first_edition, packaging_type=p_packaging_type, updated_at=NOW()
    WHERE id=v.collection_id AND user_id=p_user_id;
  END IF;
  RETURN QUERY SELECT v.success, v.collection_id, v.scan_history_id, v.scan_log_id,
    v.points_cost, v.points_discounted, v.error;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_card_entry(UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,JSONB,TEXT,BOOLEAN) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_card_entry_with_quantity(UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,JSONB,TEXT,BOOLEAN,INTEGER,TEXT,TEXT,TEXT,BOOLEAN,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_card_entry_with_quantity(UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,NUMERIC,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,JSONB,TEXT,BOOLEAN,INTEGER,TEXT,TEXT,TEXT,BOOLEAN,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.auto_sync_collection_to_portfolio() FROM PUBLIC, anon, authenticated;

COMMIT;
