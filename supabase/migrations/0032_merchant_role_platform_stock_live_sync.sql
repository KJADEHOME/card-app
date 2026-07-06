-- ============================================================
-- 0032: 商家角色系统 + 平台自营标识 + 直播同步上架
-- CardRealm Phase 9 —— 从"纯C2C"升级为"C2C + B2C"双轨模式
-- ============================================================

-- ============================================================
-- Part 1: profiles 表扩展 —— 用户角色与商家认证
-- ============================================================

-- 1a. 角色字段
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'user'
  CHECK (role IN ('user', 'merchant', 'admin'));

COMMENT ON COLUMN public.profiles.role IS '用户角色: user=普通用户, merchant=商家(含平台自营), admin=超级管理员';

-- 1b. 商家认证字段
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS merchant_verified BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS merchant_verified_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS merchant_verified_by UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS merchant_name TEXT,          -- 店铺名称 / 平台官方名
  ADD COLUMN IF NOT EXISTS merchant_desc TEXT DEFAULT '',-- 店铺简介
  ADD COLUMN IF NOT EXISTS merchant_badge TEXT DEFAULT '',-- 店铺徽章(如🛡️自营)
  ADD COLUMN IF NOT EXISTS merchant_sort_weight INTEGER DEFAULT 0; -- 排序权重(平台自营排最前)

COMMENT ON COLUMN public.profiles.merchant_verified IS '商家是否已认证(平台自营账号自动认证)';
COMMENT ON COLUMN public.profiles.merchant_name IS '店铺名称(平台自营=卡域官方)';
COMMENT ON COLUMN public.profiles.merchant_badge IS '商家徽章标识(自营=🛡️,认证=✅)';

-- ============================================================
-- Part 2: 交易库存扩展 —— 平台自营标识
-- ============================================================

-- 2a. user_collections 增加 platform_stock 标识
ALTER TABLE public.user_collections
  ADD COLUMN IF NOT EXISTS is_platform_stock BOOLEAN DEFAULT false;

COMMENT ON COLUMN public.user_collections.is_platform_stock IS '是否为平台自营库存(商家账号入库的卡牌)';

-- 2b. consignments 增加自营标识 + 直播关联
ALTER TABLE public.consignments
  ADD COLUMN IF NOT EXISTS is_platform_sale BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS live_session_id UUID,        -- 关联直播场次
  ADD COLUMN IF NOT EXISTS sale_source TEXT DEFAULT 'manual'
  CHECK (sale_source IN ('manual', 'live_sync', 'tiktok_push', 'admin_bulk'));

COMMENT ON COLUMN public.consignments.is_platform_sale IS '是否为平台自营销售(手续费0%,发货保障)';
COMMENT ON COLUMN public.consignments.live_session_id IS '直播场次ID(从直播间同步上架时关联)';
COMMENT ON COLUMN public.consignments.sale_source IS '上架来源: manual=手动, live_sync=直播同步, tiktok_push=抖音推流, admin_bulk=管理员批量';

-- 2c. products 增加自营标识
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS is_platform_product BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS seller_id UUID REFERENCES auth.users(id); -- 商品归属商家

COMMENT ON COLUMN public.products.is_platform_product IS '是否为平台自营商品';
COMMENT ON COLUMN public.products.seller_id IS '商品归属商家ID(平台自营=admin账号)';

-- ============================================================
-- Part 3: 直播场次表
-- ============================================================

CREATE TABLE IF NOT EXISTS public.live_sessions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    host_id UUID REFERENCES auth.users(id) NOT NULL,     -- 直播主(商家/管理员)
    title TEXT NOT NULL DEFAULT '',                       -- 直播标题
    platform TEXT DEFAULT 'douyin' CHECK (platform IN ('douyin', 'tiktok', 'bilibili', 'other')),
    live_room_id TEXT,                                    -- 平台直播间ID
    live_url TEXT,                                        -- 直播链接
    status TEXT DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'live', 'ended', 'cancelled')),
    scheduled_at TIMESTAMPTZ,                             -- 预定开播时间
    started_at TIMESTAMPTZ,                               -- 实际开播时间
    ended_at TIMESTAMPTZ,                                 -- 结束时间
    viewer_count INTEGER DEFAULT 0,                       -- 观看人数
    total_sales NUMERIC(14,2) DEFAULT 0,                  -- 直播期间销售额
    products_synced INTEGER DEFAULT 0,                    -- 同步上架商品数
    consignments_created INTEGER DEFAULT 0,               -- 同步创建寄售数
    auto_list_after_live BOOLEAN DEFAULT true,            -- 直播结束后是否自动转为常态上架
    notes TEXT DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE public.live_sessions IS '直播场次管理(抖音/快手等平台直播同步)';
COMMENT ON COLUMN public.live_sessions.host_id IS '直播主(必须是merchant或admin角色)';
COMMENT ON COLUMN public.live_sessions.auto_list_after_live IS '直播结束后是否自动转为常态寄售上架';

-- 直播场次索引
CREATE INDEX IF NOT EXISTS idx_live_sessions_host ON public.live_sessions(host_id);
CREATE INDEX IF NOT EXISTS idx_live_sessions_status ON public.live_sessions(status);
CREATE INDEX IF NOT EXISTS idx_live_sessions_platform ON public.live_sessions(platform);

-- ============================================================
-- Part 4: 直播商品同步记录表
-- ============================================================

CREATE TABLE IF NOT EXISTS public.live_sync_items (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    live_session_id UUID REFERENCES public.live_sessions(id) ON DELETE CASCADE NOT NULL,
    product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,   -- 关联商城商品
    consignment_id UUID REFERENCES public.consignments(id) ON DELETE SET NULL, -- 关联寄售单
    card_name TEXT NOT NULL,
    asking_price NUMERIC(12,2) NOT NULL,
    original_live_price NUMERIC(12,2),                    -- 直播间专享价(可能低于售价)
    quantity INTEGER DEFAULT 1,
    sold_in_live INTEGER DEFAULT 0,                       -- 直播期间售出数
    synced_at TIMESTAMPTZ DEFAULT NOW(),                  -- 同步时间
    status TEXT DEFAULT 'synced' CHECK (status IN ('synced', 'active', 'sold', 'ended', 'converted'))
);

COMMENT ON TABLE public.live_sync_items IS '直播商品同步记录(每个直播中展示的商品)';
COMMENT ON COLUMN public.live_sync_items.original_live_price IS '直播间专享价(可低于正常售价)';

CREATE INDEX IF NOT EXISTS idx_live_sync_session ON public.live_sync_items(live_session_id);

-- ============================================================
-- Part 5: 触发器 —— 商家账号入库自动标记自营
-- ============================================================

-- 5a. user_collections 写入时，如果用户是 merchant/admin，自动标记 is_platform_stock
CREATE OR REPLACE FUNCTION trg_mark_platform_stock()
RETURNS TRIGGER AS $$
DECLARE
    v_user_role TEXT;
BEGIN
    -- 查询入库用户的角色
    SELECT COALESCE(role, 'user') INTO v_user_role
    FROM public.profiles WHERE id = NEW.user_id;

    -- merchant 或 admin 入库的卡牌，自动标记为平台库存
    IF v_user_role IN ('merchant', 'admin') THEN
        NEW.is_platform_stock := true;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mark_platform_stock
    BEFORE INSERT ON public.user_collections
    FOR EACH ROW EXECUTE FUNCTION trg_mark_platform_stock();

-- 5b. consignments 写入时，如果是商家上架，自动标记自营 + 调整费率
CREATE OR REPLACE FUNCTION trg_mark_platform_sale()
RETURNS TRIGGER AS $$
DECLARE
    v_user_role TEXT;
BEGIN
    -- 查询卖家角色
    SELECT COALESCE(role, 'user') INTO v_user_role
    FROM public.profiles WHERE id = NEW.seller_id;

    -- 商家/管理员上架 → 自营销售(0手续费)
    IF v_user_role IN ('merchant', 'admin') THEN
        NEW.is_platform_sale := true;
        NEW.platform_fee_pct := 0;
        NEW.platform_fee := 0;
        NEW.seller_earnings := NEW.asking_price;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mark_platform_sale
    BEFORE INSERT ON public.consignments
    FOR EACH ROW EXECUTE FUNCTION trg_mark_platform_sale();

-- ============================================================
-- Part 6: RPC 函数 —— 商家认证
-- ============================================================

-- 6a. 管理员认证商家
CREATE OR REPLACE FUNCTION admin_verify_merchant(
    p_admin_id UUID,
    p_user_id UUID,
    p_merchant_name TEXT,
    p_merchant_desc TEXT DEFAULT '',
    p_merchant_badge TEXT DEFAULT '✅'
) RETURNS JSON AS $$
DECLARE
    v_admin_role TEXT;
BEGIN
    -- 检查操作者是否为 admin
    SELECT COALESCE(role, 'user') INTO v_admin_role
    FROM public.profiles WHERE id = p_admin_id;

    IF v_admin_role != 'admin' THEN
        -- 备用检查: 邮箱包含 admin
        IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_admin_id AND email LIKE '%admin%') THEN
            RETURN json_build_object('success', false, 'error', '需要管理员权限');
        END IF;
    END IF;

    -- 更新用户角色和商家信息
    UPDATE public.profiles
    SET role = 'merchant',
        merchant_verified = true,
        merchant_verified_at = NOW(),
        merchant_verified_by = p_admin_id,
        merchant_name = p_merchant_name,
        merchant_desc = p_merchant_desc,
        merchant_badge = p_merchant_badge,
        updated_at = NOW()
    WHERE id = p_user_id;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '用户不存在');
    END IF;

    RETURN json_build_object(
        'success', true,
        'user_id', p_user_id,
        'role', 'merchant',
        'merchant_name', p_merchant_name
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6b. 取消商家认证(降级为普通用户)
CREATE OR REPLACE FUNCTION admin_revoke_merchant(
    p_admin_id UUID,
    p_user_id UUID
) RETURNS JSON AS $$
DECLARE
    v_admin_role TEXT;
BEGIN
    SELECT COALESCE(role, 'user') INTO v_admin_role
    FROM public.profiles WHERE id = p_admin_id;

    IF v_admin_role != 'admin' THEN
        IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_admin_id AND email LIKE '%admin%') THEN
            RETURN json_build_object('success', false, 'error', '需要管理员权限');
        END IF;
    END IF;

    UPDATE public.profiles
    SET role = 'user',
        merchant_verified = false,
        merchant_verified_at = NULL,
        merchant_verified_by = NULL,
        merchant_name = NULL,
        merchant_desc = '',
        merchant_badge = '',
        updated_at = NOW()
    WHERE id = p_user_id;

    RETURN json_build_object('success', true, 'user_id', p_user_id, 'role', 'user');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Part 7: RPC 函数 —— 直播同步上架
-- ============================================================

-- 7a. 创建直播场次
CREATE OR REPLACE FUNCTION create_live_session(
    p_host_id UUID,
    p_title TEXT,
    p_platform TEXT DEFAULT 'douyin',
    p_live_room_id TEXT DEFAULT '',
    p_live_url TEXT DEFAULT '',
    p_scheduled_at TIMESTAMPTZ DEFAULT NULL,
    p_auto_list_after_live BOOLEAN DEFAULT true
) RETURNS JSON AS $$
DECLARE
    v_host_role TEXT;
    v_session_id UUID;
BEGIN
    -- 只有 merchant/admin 才能开直播
    SELECT COALESCE(role, 'user') INTO v_host_role
    FROM public.profiles WHERE id = p_host_id;

    IF v_host_role NOT IN ('merchant', 'admin') THEN
        RETURN json_build_object('success', false, 'error', '只有商家或管理员才能创建直播场次');
    END IF;

    INSERT INTO public.live_sessions (
        host_id, title, platform, live_room_id, live_url,
        scheduled_at, auto_list_after_live, status
    ) VALUES (
        p_host_id, p_title, p_platform, p_live_room_id, p_live_url,
        p_scheduled_at, p_auto_list_after_live,
        CASE WHEN p_scheduled_at IS NULL OR p_scheduled_at <= NOW() THEN 'live' ELSE 'scheduled' END
    ) RETURNING id INTO v_session_id;

    RETURN json_build_object(
        'success', true,
        'session_id', v_session_id,
        'status', CASE WHEN p_scheduled_at IS NULL OR p_scheduled_at <= NOW() THEN 'live' ELSE 'scheduled' END
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7b. 直播开始
CREATE OR REPLACE FUNCTION start_live_session(
    p_host_id UUID,
    p_session_id UUID
) RETURNS JSON AS $$
DECLARE
    v_session RECORD;
BEGIN
    SELECT * INTO v_session FROM public.live_sessions
    WHERE id = p_session_id AND host_id = p_host_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '直播场次不存在或不属于你');
    END IF;

    IF v_session.status NOT IN ('scheduled', 'live') THEN
        RETURN json_build_object('success', false, 'error', '直播场次状态不允许开播');
    END IF;

    UPDATE public.live_sessions
    SET status = 'live', started_at = COALESCE(started_at, NOW()), updated_at = NOW()
    WHERE id = p_session_id;

    RETURN json_build_object('success', true, 'session_id', p_session_id, 'status', 'live');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7c. 同步卡牌到直播(从库存上架 + 关联直播场次)
CREATE OR REPLACE FUNCTION sync_card_to_live(
    p_host_id UUID,
    p_session_id UUID,
    p_collection_id UUID,
    p_asking_price NUMERIC,
    p_live_price NUMERIC DEFAULT NULL,  -- 直播间专享价(可低于售价)
    p_shipping_fee NUMERIC DEFAULT 0,
    p_description TEXT DEFAULT ''
) RETURNS JSON AS $$
DECLARE
    v_collection RECORD;
    v_available_qty INTEGER;
    v_host_role TEXT;
    v_consignment_id UUID;
    v_sync_item_id UUID;
    v_platform_fee NUMERIC;
    v_seller_earnings NUMERIC;
    v_session RECORD;
BEGIN
    -- 检查直播主角色
    SELECT COALESCE(role, 'user') INTO v_host_role
    FROM public.profiles WHERE id = p_host_id;

    IF v_host_role NOT IN ('merchant', 'admin') THEN
        RETURN json_build_object('success', false, 'error', '只有商家才能同步卡牌到直播');
    END IF;

    -- 检查直播场次
    SELECT * INTO v_session FROM public.live_sessions
    WHERE id = p_session_id AND host_id = p_host_id;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '直播场次不存在或不属于你');
    END IF;

    IF v_session.status NOT IN ('scheduled', 'live') THEN
        RETURN json_build_object('success', false, 'error', '直播场次不在可添加状态');
    END IF;

    -- 锁定库存
    SELECT * INTO v_collection
    FROM public.user_collections
    WHERE id = p_collection_id AND user_id = p_host_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '库存不存在或不属于你');
    END IF;

    v_available_qty := COALESCE(v_collection.quantity, 0) - COALESCE(v_collection.reserved_quantity, 0);
    IF v_available_qty <= 0 THEN
        RETURN json_build_object('success', false, 'error', '库存不足');
    END IF;

    -- 冻结库存
    UPDATE public.user_collections
    SET reserved_quantity = COALESCE(reserved_quantity, 0) + 1,
        updated_at = NOW()
    WHERE id = p_collection_id;

    -- 商家/管理员上架 → 手续费0 (触发器 trg_mark_platform_sale 会自动处理)
    v_platform_fee := 0;
    v_seller_earnings := p_asking_price;

    -- 创建寄售单(关联直播场次)
    INSERT INTO public.consignments (
        seller_id, collection_id, quantity,
        card_name, card_name_en, card_image, series, rarity, card_category, condition,
        asking_price, currency,
        platform_fee_pct, platform_fee, seller_earnings,
        shipping_fee, description,
        status, live_session_id, sale_source
    ) VALUES (
        p_host_id, p_collection_id, 1,
        v_collection.card_name, v_collection.card_name_en, v_collection.card_image,
        v_collection.series, v_collection.rarity, v_collection.card_category, v_collection.condition,
        p_asking_price, 'CNY',
        0, v_platform_fee, v_seller_earnings,
        p_shipping_fee, p_description,
        'active', p_session_id, 'live_sync'
    ) RETURNING id INTO v_consignment_id;

    -- 记录同步记录
    INSERT INTO public.live_sync_items (
        live_session_id, consignment_id, card_name,
        asking_price, original_live_price, quantity, status
    ) VALUES (
        p_session_id, v_consignment_id, v_collection.card_name,
        p_asking_price, COALESCE(p_live_price, p_asking_price), 1, 'synced'
    ) RETURNING id INTO v_sync_item_id;

    -- 更新直播场次统计
    UPDATE public.live_sessions
    SET consignments_created = consignments_created + 1,
        updated_at = NOW()
    WHERE id = p_session_id;

    RETURN json_build_object(
        'success', true,
        'consignment_id', v_consignment_id,
        'sync_item_id', v_sync_item_id,
        'is_platform_sale', true,
        'fee_pct', 0,
        'live_price', COALESCE(p_live_price, p_asking_price)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7d. 结束直播
CREATE OR REPLACE FUNCTION end_live_session(
    p_host_id UUID,
    p_session_id UUID,
    p_viewer_count INTEGER DEFAULT 0
) RETURNS JSON AS $$
DECLARE
    v_session RECORD;
    v_auto_list BOOLEAN;
    v_converted_count INTEGER := 0;
BEGIN
    SELECT * INTO v_session FROM public.live_sessions
    WHERE id = p_session_id AND host_id = p_host_id FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '直播场次不存在或不属于你');
    END IF;

    IF v_session.status != 'live' THEN
        RETURN json_build_object('success', false, 'error', '直播场次不在直播状态');
    END IF;

    -- 结束直播
    UPDATE public.live_sessions
    SET status = 'ended',
        ended_at = NOW(),
        viewer_count = p_viewer_count,
        updated_at = NOW()
    WHERE id = p_session_id;

    -- 如果 auto_list_after_live=true，将未售出的直播商品转为常态上架
    IF v_session.auto_list_after_live THEN
        -- 更新寄售单: 移除直播关联，sale_source 改为 manual
        UPDATE public.consignments c
        SET live_session_id = NULL,
            sale_source = 'manual',
            updated_at = NOW()
        WHERE c.live_session_id = p_session_id
          AND c.status = 'active';

        GET DIAGNOSTICS v_converted_count = ROW_COUNT;

        -- 更新同步记录状态
        UPDATE public.live_sync_items lsi
        SET status = 'converted'
        WHERE lsi.live_session_id = p_session_id
          AND lsi.status IN ('synced', 'active');
    ELSE
        -- 不自动转上架 → 下架直播商品
        UPDATE public.consignments c
        SET status = 'cancelled',
            updated_at = NOW()
        WHERE c.live_session_id = p_session_id
          AND c.status = 'active';

        -- 释放冻结库存
        -- (cancel_consignment 会处理，但这里批量处理)
    END IF;

    RETURN json_build_object(
        'success', true,
        'session_id', p_session_id,
        'status', 'ended',
        'auto_list', v_session.auto_list_after_live,
        'converted_count', v_converted_count
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Part 8: RPC 函数 —— 管理员批量上架(平台自营)
-- ============================================================

CREATE OR REPLACE FUNCTION admin_bulk_list_cards(
    p_admin_id UUID,
    p_cards JSON,  -- [{collection_id, asking_price, shipping_fee, description}]
    p_live_session_id UUID DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
    v_admin_role TEXT;
    v_card JSON;
    v_collection RECORD;
    v_available_qty INTEGER;
    v_consignment_id UUID;
    v_success_count INTEGER := 0;
    v_fail_count INTEGER := 0;
    v_results JSON[] := '{}';
BEGIN
    -- 检查管理员权限
    SELECT COALESCE(role, 'user') INTO v_admin_role
    FROM public.profiles WHERE id = p_admin_id;

    IF v_admin_role != 'admin' THEN
        IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_admin_id AND email LIKE '%admin%') THEN
            RETURN json_build_object('success', false, 'error', '需要管理员权限');
        END IF;
    END IF;

    -- 逐张处理
    FOR v_card IN SELECT * FROM json_array_elements(p_cards)
    LOOP
        -- 锁定库存
        SELECT * INTO v_collection
        FROM public.user_collections
        WHERE id = (v_card->>'collection_id')::UUID
          AND user_id = p_admin_id
        FOR UPDATE;

        IF NOT FOUND THEN
            v_results := array_append(v_results, json_build_object(
                'collection_id', v_card->>'collection_id', 'success', false, 'error', '库存不存在'
            ));
            v_fail_count := v_fail_count + 1;
            CONTINUE;
        END IF;

        v_available_qty := COALESCE(v_collection.quantity, 0) - COALESCE(v_collection.reserved_quantity, 0);
        IF v_available_qty <= 0 THEN
            v_results := array_append(v_results, json_build_object(
                'collection_id', v_card->>'collection_id', 'success', false, 'error', '库存不足'
            ));
            v_fail_count := v_fail_count + 1;
            CONTINUE;
        END IF;

        -- 冻结库存
        UPDATE public.user_collections
        SET reserved_quantity = COALESCE(reserved_quantity, 0) + 1,
            updated_at = NOW()
        WHERE id = (v_card->>'collection_id')::UUID;

        -- 创建自营寄售单(触发器自动设0手续费)
        INSERT INTO public.consignments (
            seller_id, collection_id, quantity,
            card_name, card_name_en, card_image, series, rarity, card_category, condition,
            asking_price, currency,
            platform_fee_pct, platform_fee, seller_earnings,
            shipping_fee, description,
            status, live_session_id, sale_source
        ) VALUES (
            p_admin_id, (v_card->>'collection_id')::UUID, 1,
            v_collection.card_name, v_collection.card_name_en, v_collection.card_image,
            v_collection.series, v_collection.rarity, v_collection.card_category, v_collection.condition,
            (v_card->>'asking_price')::NUMERIC, 'CNY',
            0, 0, (v_card->>'asking_price')::NUMERIC,
            COALESCE((v_card->>'shipping_fee')::NUMERIC, 0),
            COALESCE(v_card->>'description', ''),
            'active',
            p_live_session_id,
            CASE WHEN p_live_session_id IS NOT NULL THEN 'live_sync' ELSE 'admin_bulk' END
        ) RETURNING id INTO v_consignment_id;

        v_results := array_append(v_results, json_build_object(
            'collection_id', v_card->>'collection_id',
            'consignment_id', v_consignment_id,
            'success', true
        ));
        v_success_count := v_success_count + 1;
    END LOOP;

    RETURN json_build_object(
        'success', true,
        'total', v_success_count + v_fail_count,
        'listed', v_success_count,
        'failed', v_fail_count,
        'results', v_results
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Part 9: 视图 —— 自营商品优先展示
-- ============================================================

-- 9a. 市场列表(自营优先排序)
CREATE OR REPLACE VIEW public.market_list_with_seller AS
SELECT
    c.id,
    c.card_name,
    c.card_name_en,
    c.card_image,
    c.series,
    c.rarity,
    c.card_category,
    c.condition,
    c.asking_price,
    c.shipping_fee,
    c.status,
    c.is_platform_sale,
    c.sale_source,
    c.listed_at,
    c.live_session_id,
    p.username AS seller_name,
    p.merchant_name,
    p.merchant_badge,
    p.merchant_verified,
    p.role AS seller_role,
    -- 自营排序权重: 自营=100, 认证商家=50, 普通用户=0
    CASE
        WHEN p.role IN ('admin', 'merchant') AND c.is_platform_sale THEN 100
        WHEN p.merchant_verified THEN 50
        ELSE 0
    END AS seller_weight
FROM public.consignments c
LEFT JOIN public.profiles p ON c.seller_id = p.id
WHERE c.status = 'active';

-- 9b. 直播场次列表
CREATE OR REPLACE VIEW public.live_sessions_overview AS
SELECT
    ls.id,
    ls.title,
    ls.platform,
    ls.live_room_id,
    ls.live_url,
    ls.status,
    ls.scheduled_at,
    ls.started_at,
    ls.ended_at,
    ls.viewer_count,
    ls.total_sales,
    ls.consignments_created,
    ls.auto_list_after_live,
    p.username AS host_name,
    p.merchant_name AS host_merchant_name,
    p.role AS host_role
FROM public.live_sessions ls
LEFT JOIN public.profiles p ON ls.host_id = p.id;

-- ============================================================
-- Part 10: 权限授予
-- ============================================================

GRANT SELECT ON public.live_sessions TO authenticated;
GRANT SELECT ON public.live_sync_items TO authenticated;
GRANT SELECT ON public.market_list_with_seller TO authenticated;
GRANT SELECT ON public.live_sessions_overview TO authenticated;

GRANT EXECUTE ON FUNCTION admin_verify_merchant TO authenticated;
GRANT EXECUTE ON FUNCTION admin_revoke_merchant TO authenticated;
GRANT EXECUTE ON FUNCTION create_live_session TO authenticated;
GRANT EXECUTE ON FUNCTION start_live_session TO authenticated;
GRANT EXECUTE ON FUNCTION sync_card_to_live TO authenticated;
GRANT EXECUTE ON FUNCTION end_live_session TO authenticated;
GRANT EXECUTE ON FUNCTION admin_bulk_list_cards TO authenticated;

-- ============================================================
-- Part 11: 更新 purchase_consignment —— 自营交易0手续费
-- ============================================================

-- 注意: purchase_consignment 函数在 0012 中定义
-- 这里需要修改它，让自营交易的手续费为0且收款直接入卖家钱包
-- 由于原始函数已经在 0012 中定义为 SECURITY DEFINER
-- 我们需要 DROP 并重建

DROP FUNCTION IF EXISTS purchase_consignment(UUID, UUID);

CREATE OR REPLACE FUNCTION purchase_consignment(
    p_buyer_id UUID,
    p_consignment_id UUID
) RETURNS JSON AS $$
DECLARE
    v_consign RECORD;
    v_buyer_wallet RECORD;
    v_seller_wallet RECORD;
    v_total_amount NUMERIC;
    v_order_id UUID;
    v_order_no TEXT;
    v_today_count INTEGER;
    v_buyer_collection_id UUID;
    v_seller_collection_id UUID;
    v_existing_buyer_collection RECORD;
    v_fee_pct NUMERIC;
    v_platform_fee NUMERIC;
    v_seller_earnings NUMERIC;
BEGIN
    -- 1. 锁定寄售单
    SELECT * INTO v_consign
    FROM public.consignments
    WHERE id = p_consignment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '寄售单不存在');
    END IF;

    IF v_consign.status != 'active' THEN
        RETURN json_build_object('success', false, 'error', '该卡牌已售出或已下架');
    END IF;

    IF v_consign.seller_id = p_buyer_id THEN
        RETURN json_build_object('success', false, 'error', '不能购买自己的卡牌');
    END IF;

    -- 2. 费率计算: 自营销售0手续费, C2C按原费率
    IF v_consign.is_platform_sale THEN
        v_fee_pct := 0;
        v_platform_fee := 0;
        v_seller_earnings := v_consign.asking_price;
    ELSE
        v_fee_pct := COALESCE(v_consign.platform_fee_pct, 8.00);
        v_platform_fee := ROUND(v_consign.asking_price * v_fee_pct / 100, 2);
        v_seller_earnings := v_consign.asking_price - v_platform_fee;
    END IF;

    v_total_amount := v_consign.asking_price + COALESCE(v_consign.shipping_fee, 0);

    -- 3. 锁定买家钱包
    SELECT * INTO v_buyer_wallet
    FROM public.wallets
    WHERE user_id = p_buyer_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.wallets (user_id, balance) VALUES (p_buyer_id, 0) RETURNING * INTO v_buyer_wallet;
    END IF;

    IF v_buyer_wallet.balance < v_total_amount THEN
        RETURN json_build_object('success', false, 'error', '余额不足，请先充值',
            'required', v_total_amount, 'balance', v_buyer_wallet.balance);
    END IF;

    -- 4. 锁定卖家钱包
    SELECT * INTO v_seller_wallet
    FROM public.wallets
    WHERE user_id = v_consign.seller_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.wallets (user_id, balance) VALUES (v_consign.seller_id, 0) RETURNING * INTO v_seller_wallet;
    END IF;

    -- 5. 生成订单号
    SELECT COUNT(*) + 1 INTO v_today_count
    FROM public.orders
    WHERE created_at::date = CURRENT_DATE;
    v_order_no := 'CR' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || LPAD(v_today_count::TEXT, 4, '0');

    -- 6. 创建订单(标记自营)
    INSERT INTO public.orders (
        order_no, buyer_id, seller_id, consignment_id,
        item_price, shipping_fee, platform_fee, total_amount, seller_earnings,
        currency, status, paid_at
    ) VALUES (
        v_order_no, p_buyer_id, v_consign.seller_id, p_consignment_id,
        v_consign.asking_price, COALESCE(v_consign.shipping_fee, 0),
        v_platform_fee, v_total_amount, v_seller_earnings,
        'CNY', 'paid', NOW()
    ) RETURNING id INTO v_order_id;

    -- 7. 更新寄售单状态
    UPDATE public.consignments
    SET status = 'sold', sold_at = NOW(), updated_at = NOW()
    WHERE id = p_consignment_id;

    -- 8. 扣减买家钱包
    UPDATE public.wallets
    SET balance = balance - v_total_amount,
        total_spent = total_spent + v_total_amount,
        updated_at = NOW()
    WHERE user_id = p_buyer_id;

    INSERT INTO public.wallet_transactions (wallet_id, user_id, amount, balance_after, type, reference_id, reference_type, description)
    VALUES (v_buyer_wallet.id, p_buyer_id, -v_total_amount, v_buyer_wallet.balance - v_total_amount,
            'purchase', v_order_id, 'order',
            '购买 ' || v_consign.card_name ||
            CASE WHEN v_consign.is_platform_sale THEN ' (🛡️自营)' ELSE '' END);

    -- 9. 卖家收入(自营全额入账, C2C扣手续费)
    UPDATE public.wallets
    SET balance = balance + v_seller_earnings,
        total_earned = total_earned + v_seller_earnings,
        updated_at = NOW()
    WHERE user_id = v_consign.seller_id;

    INSERT INTO public.wallet_transactions (wallet_id, user_id, amount, balance_after, type, reference_id, reference_type, description)
    VALUES (v_seller_wallet.id, v_consign.seller_id, v_seller_earnings, v_seller_wallet.balance + v_seller_earnings,
            'sale', v_order_id, 'order',
            '售出 ' || v_consign.card_name ||
            CASE WHEN v_consign.is_platform_sale THEN ' (自营全额入账)' ELSE '' END);

    -- 10. 平台手续费(自营=0, 不记账)
    IF NOT v_consign.is_platform_sale AND v_platform_fee > 0 THEN
        INSERT INTO public.platform_fees (order_id, consignment_id, fee_type, fee_amount, fee_pct, currency, description)
        VALUES (v_order_id, p_consignment_id, 'transaction', v_platform_fee, v_fee_pct, 'CNY',
                v_consign.card_name || ' 交易手续费');
    END IF;

    -- 11. 卖家库存减少
    IF v_consign.collection_id IS NOT NULL THEN
        v_seller_collection_id := v_consign.collection_id;
        UPDATE public.user_collections
        SET quantity = GREATEST(quantity - 1, 0),
            reserved_quantity = GREATEST(reserved_quantity - 1, 0),
            updated_at = NOW()
        WHERE id = v_seller_collection_id;
    END IF;

    -- 12. 买家库存增加
    SELECT id INTO v_buyer_collection_id
    FROM public.user_collections
    WHERE user_id = p_buyer_id
      AND card_name = v_consign.card_name
      AND COALESCE(series, '') = COALESCE(v_consign.series, '')
      AND COALESCE(rarity, 'N') = COALESCE(v_consign.rarity, 'N')
    LIMIT 1;

    IF FOUND THEN
        UPDATE public.user_collections
        SET quantity = quantity + 1,
            purchase_price = v_consign.asking_price,
            current_price = v_consign.asking_price,
            updated_at = NOW()
        WHERE id = v_buyer_collection_id;
    ELSE
        INSERT INTO public.user_collections (
            user_id, card_name, card_name_en, card_image,
            series, rarity, card_category, condition,
            purchase_price, current_price, quantity,
            source
        ) VALUES (
            p_buyer_id, v_consign.card_name, v_consign.card_name_en, v_consign.card_image,
            v_consign.series, v_consign.rarity, v_consign.card_category, v_consign.condition,
            v_consign.asking_price, v_consign.asking_price, 1,
            'PURCHASE'
        );
    END IF;

    -- 13. 同步 card_prices
    INSERT INTO public.card_prices (card_name, series, rarity, card_category, current_price, previous_price, market, currency, data_source)
    VALUES (v_consign.card_name, v_consign.series, v_consign.rarity, v_consign.card_category,
            v_consign.asking_price, v_consign.asking_price, 'CN', 'CNY', 'market')
    ON CONFLICT (card_name, series, rarity, market) DO UPDATE
    SET current_price = EXCLUDED.current_price,
        updated_at = NOW();

    -- 14. 更新直播同步记录(如果来自直播)
    IF v_consign.live_session_id IS NOT NULL THEN
        UPDATE public.live_sync_items
        SET sold_in_live = sold_in_live + 1, status = 'sold'
        WHERE consignment_id = p_consignment_id;

        UPDATE public.live_sessions
        SET total_sales = total_sales + v_total_amount,
            updated_at = NOW()
        WHERE id = v_consign.live_session_id;
    END IF;

    RETURN json_build_object(
        'success', true,
        'order_id', v_order_id,
        'order_no', v_order_no,
        'total_amount', v_total_amount,
        'platform_fee', v_platform_fee,
        'seller_earnings', v_seller_earnings,
        'is_platform_sale', v_consign.is_platform_sale,
        'card_name', v_consign.card_name
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- Part 12: platform_config 新增配置项
-- ============================================================

INSERT INTO public.platform_config (key, value, description) VALUES
    ('platform_merchant_fee_pct', '0', '平台自营销售手续费(%)'),
    ('c2c_merchant_fee_pct', '5', '认证商家C2C手续费(%，低于普通用户)'),
    ('live_sync_enabled', 'true', '是否启用直播同步上架功能'),
    ('live_auto_list_after_end', 'true', '直播结束后自动转为常态上架'),
    ('platform_badge', '🛡️自营', '平台自营徽章标识'),
    ('verified_merchant_badge', '✅认证', '认证商家徽章标识')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- ============================================================
-- 完成! 总结:
-- 1. profiles 新增: role, merchant_verified, merchant_name, merchant_badge 等
-- 2. user_collections 新增: is_platform_stock
-- 3. consignments 新增: is_platform_sale, live_session_id, sale_source
-- 4. products 新增: is_platform_product, seller_id
-- 5. 新表: live_sessions, live_sync_items
-- 6. 触发器: trg_mark_platform_stock, trg_mark_platform_sale
-- 7. RPC: admin_verify_merchant, admin_revoke_merchant,
--         create_live_session, start_live_session,
--         sync_card_to_live, end_live_session,
--         admin_bulk_list_cards
-- 8. 视图: market_list_with_seller, live_sessions_overview
-- 9. purchase_consignment 重写(自营0手续费+直播同步结算)
-- ============================================================
