-- 0040_admin_rpc_group_a.sql
-- SH-003C Phase 3 Group A: unified platform admin login/publish authentication
-- Depends on: 0038_admin_auth_unification_phase1.sql, 0039_admin_orders_rpc.sql

BEGIN;

-- New platform publications belong to Supabase Auth administrators.
-- Preserve legacy admin_id for historic rows, but do not require a legacy admins row.
ALTER TABLE public.platform_cards
    ADD COLUMN IF NOT EXISTS auth_admin_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.platform_cards ALTER COLUMN admin_id DROP NOT NULL;
CREATE INDEX IF NOT EXISTS idx_platform_cards_auth_admin
    ON public.platform_cards(auth_admin_id, created_at DESC);

COMMENT ON COLUMN public.platform_cards.auth_admin_id IS
    'SH-003C Phase 3: Supabase Auth administrator who issued this platform item.';

-- Secure overload: no token/admin-id parameter. Identity comes exclusively from auth.uid().
CREATE OR REPLACE FUNCTION public.admin_publish_card(
    p_name TEXT,
    p_set_name TEXT DEFAULT '',
    p_card_image_url TEXT DEFAULT NULL,
    p_images TEXT[] DEFAULT '{}',
    p_thumbnail_url TEXT DEFAULT NULL,
    p_description TEXT DEFAULT '',
    p_card_category TEXT DEFAULT 'pokemon',
    p_rarity TEXT DEFAULT 'N',
    p_condition TEXT DEFAULT 'NM',
    p_initial_cost_price NUMERIC DEFAULT 0,
    p_listing_price NUMERIC DEFAULT 0,
    p_stock_quantity INTEGER DEFAULT 1,
    p_platform_fee_pct NUMERIC DEFAULT 0,
    p_shipping_fee NUMERIC DEFAULT 0
)
RETURNS TABLE(
    success BOOLEAN,
    platform_card_id UUID,
    card_market_id UUID,
    final_price NUMERIC,
    mark_price NUMERIC,
    error TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_admin_id UUID;
    v_platform_card_id UUID;
    v_card_market_id UUID;
    v_final_price NUMERIC;
    v_mark_price NUMERIC;
BEGIN
    v_admin_id := public.require_admin();

    p_name := BTRIM(COALESCE(p_name, ''));
    IF p_name = '' OR LENGTH(p_name) > 200 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC,
            '卡牌名称不能为空且不能超过200字符'::TEXT;
        RETURN;
    END IF;
    IF p_listing_price IS NULL OR p_listing_price < 0 OR p_listing_price > 100000000 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC,
            '上架价不合法'::TEXT;
        RETURN;
    END IF;
    IF p_initial_cost_price IS NULL OR p_initial_cost_price < 0 OR p_initial_cost_price > 100000000 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC,
            '成本价不合法'::TEXT;
        RETURN;
    END IF;
    IF p_stock_quantity IS NULL OR p_stock_quantity < 0 OR p_stock_quantity > 1000000 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC,
            '库存数量不合法'::TEXT;
        RETURN;
    END IF;
    IF COALESCE(p_platform_fee_pct, 0) < 0 OR COALESCE(p_platform_fee_pct, 0) > 100 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC,
            '平台费率不合法'::TEXT;
        RETURN;
    END IF;
    IF COALESCE(p_shipping_fee, 0) < 0 OR COALESCE(p_shipping_fee, 0) > 1000000 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC,
            '运费不合法'::TEXT;
        RETURN;
    END IF;
    IF COALESCE(p_condition, 'NM') NOT IN ('M','NM','LP','MP','HP','D') THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC,
            '品相不合法'::TEXT;
        RETURN;
    END IF;

    INSERT INTO public.card_market (
        card_name, series, rarity, card_category, market,
        market_price, market_source, ai_estimate_price, ai_model, source_type
    ) VALUES (
        p_name, LEFT(COALESCE(p_set_name, ''), 200), LEFT(COALESCE(p_rarity, 'N'), 50),
        LEFT(COALESCE(p_card_category, 'other'), 50), 'CN',
        p_listing_price, 'platform_issue', p_listing_price, 'platform_admin', 'platform'
    )
    ON CONFLICT (card_name, series, rarity, market)
    DO UPDATE SET
        market_price = EXCLUDED.market_price,
        market_source = EXCLUDED.market_source,
        ai_estimate_price = EXCLUDED.ai_estimate_price,
        ai_model = EXCLUDED.ai_model,
        source_type = 'platform',
        updated_at = NOW()
    RETURNING id INTO v_card_market_id;

    SELECT cm.final_price, cm.mark_price
      INTO v_final_price, v_mark_price
      FROM public.card_market cm
     WHERE cm.id = v_card_market_id;

    INSERT INTO public.platform_cards (
        admin_id, auth_admin_id, name, name_en, set_name, card_image_url, images, thumbnail_url,
        description, card_category, rarity, condition,
        initial_cost_price, listing_price, mark_price,
        stock_quantity, status, source, card_market_id,
        platform_fee_pct, shipping_fee
    ) VALUES (
        NULL, v_admin_id, p_name, NULL, LEFT(COALESCE(p_set_name, ''), 200), p_card_image_url,
        COALESCE(p_images, '{}'), p_thumbnail_url, LEFT(COALESCE(p_description, ''), 5000),
        LEFT(COALESCE(p_card_category, 'other'), 50), LEFT(COALESCE(p_rarity, 'N'), 50), p_condition,
        p_initial_cost_price, p_listing_price, v_mark_price,
        p_stock_quantity, CASE WHEN p_stock_quantity > 0 THEN 'active' ELSE 'sold_out' END,
        'platform', v_card_market_id, COALESCE(p_platform_fee_pct, 0), COALESCE(p_shipping_fee, 0)
    ) RETURNING id INTO v_platform_card_id;

    PERFORM public.log_admin_action(
        'publish_card', 'platform_card', v_platform_card_id,
        jsonb_build_object(
            'name', p_name,
            'listing_price', p_listing_price,
            'stock_quantity', p_stock_quantity,
            'card_market_id', v_card_market_id
        )
    );

    RETURN QUERY SELECT true, v_platform_card_id, v_card_market_id,
        v_final_price, v_mark_price, NULL::TEXT;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_publish_card(
    TEXT,TEXT,TEXT,TEXT[],TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,NUMERIC,INTEGER,NUMERIC,NUMERIC
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_publish_card(
    TEXT,TEXT,TEXT,TEXT[],TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,NUMERIC,INTEGER,NUMERIC,NUMERIC
) TO authenticated;

-- Legacy independent-login RPCs are no longer callable by browser roles.
REVOKE ALL ON FUNCTION public.admin_login(TEXT,TEXT,INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.verify_admin_token(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_logout(TEXT) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.admin_login(TEXT,TEXT,INTEGER) IS
    'DEPRECATED SH-003C Phase 3: legacy admins.session_token login; browser EXECUTE revoked.';
COMMENT ON FUNCTION public.verify_admin_token(TEXT) IS
    'DEPRECATED SH-003C Phase 3: legacy token verifier; browser EXECUTE revoked.';
COMMENT ON FUNCTION public.admin_logout(TEXT) IS
    'DEPRECATED SH-003C Phase 3: legacy token logout; browser EXECUTE revoked.';

COMMIT;

-- Rollback notes (manual, test environment first):
-- GRANT EXECUTE ON FUNCTION public.admin_login(TEXT,TEXT,INTEGER) TO anon, authenticated;
-- GRANT EXECUTE ON FUNCTION public.verify_admin_token(TEXT) TO anon, authenticated;
-- GRANT EXECUTE ON FUNCTION public.admin_logout(TEXT) TO anon, authenticated;
-- DROP FUNCTION public.admin_publish_card(TEXT,TEXT,TEXT,TEXT[],TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,NUMERIC,INTEGER,NUMERIC,NUMERIC);
-- ALTER TABLE public.platform_cards DROP COLUMN IF EXISTS auth_admin_id;
-- ALTER TABLE public.platform_cards ALTER COLUMN admin_id SET NOT NULL; -- only after proving no NULL rows
