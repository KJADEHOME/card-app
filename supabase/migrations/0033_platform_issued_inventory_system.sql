-- ============================================
-- 0033: 平台方商品发行系统（Platform Issued Inventory System）
-- ============================================
-- 目标：构建"平台官方卡牌上架 + 用户市场交易"双层商品体系
-- 依赖: 0032 (商家角色+自营标识+直播同步)
-- 约束：不破坏 pricing engine, 不修改 final_price 规则

-- ============================================
-- Part 1: 扩展 pgcrypto（管理员密码哈希）
-- ============================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- 注意：pgcrypto 函数位于 extensions schema，函数内需显式使用 extensions.crypt / extensions.gen_salt

-- ============================================
-- Part 2: 独立管理员表（admins）
-- ============================================
CREATE TABLE IF NOT EXISTS public.admins (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'platform_admin' CHECK (role IN ('platform_admin', 'super_admin')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'suspended')),
    display_name TEXT,
    email TEXT,
    last_login_at TIMESTAMPTZ,
    session_token TEXT,
    token_expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE public.admins IS '平台独立管理员系统（与 auth.users 隔离）';
COMMENT ON COLUMN public.admins.password_hash IS 'pgcrypto crypt() 生成的 bcrypt 哈希';

-- 创建默认平台管理员（密码：PlatformAdmin2026!）
-- 注意：生产环境应通过安全渠道初始化，此处为快速启动
INSERT INTO public.admins (username, password_hash, role, display_name, email, status)
VALUES (
    'platform_admin',
    extensions.crypt('PlatformAdmin2026!', extensions.gen_salt('bf', 8)),
    'super_admin',
    '平台发行管理员',
    'platform@cardrealm.top',
    'active'
)
ON CONFLICT (username) DO UPDATE SET
    password_hash = EXCLUDED.password_hash,
    role = EXCLUDED.role,
    status = EXCLUDED.status,
    updated_at = NOW();

-- ============================================
-- Part 3: 平台发行卡牌表（platform_cards）
-- ============================================
CREATE TABLE IF NOT EXISTS public.platform_cards (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    admin_id UUID REFERENCES public.admins(id) ON DELETE SET NULL NOT NULL,
    name TEXT NOT NULL,
    name_en TEXT,
    set_name TEXT,
    card_image_url TEXT,
    images TEXT[] DEFAULT '{}',
    thumbnail_url TEXT,
    description TEXT,
    card_category TEXT DEFAULT 'pokemon',
    rarity TEXT DEFAULT 'N',
    condition TEXT DEFAULT 'NM' CHECK (condition IN ('M', 'NM', 'LP', 'MP', 'HP', 'D')),
    initial_cost_price NUMERIC(12,2) DEFAULT 0 CHECK (initial_cost_price >= 0),
    listing_price NUMERIC(12,2) NOT NULL CHECK (listing_price >= 0),
    mark_price NUMERIC(12,2),
    stock_quantity INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    reserved_quantity INTEGER NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),
    sold_quantity INTEGER NOT NULL DEFAULT 0 CHECK (sold_quantity >= 0),
    available_quantity INTEGER GENERATED ALWAYS AS (GREATEST(stock_quantity - reserved_quantity - sold_quantity, 0)) STORED,
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'sold_out')),
    source TEXT NOT NULL DEFAULT 'platform' CHECK (source IN ('platform')),
    card_market_id UUID REFERENCES public.card_market(id) ON DELETE SET NULL,
    -- 预留支付相关
    platform_fee_pct NUMERIC(5,2) DEFAULT 0 CHECK (platform_fee_pct >= 0),
    shipping_fee NUMERIC(12,2) DEFAULT 0 CHECK (shipping_fee >= 0),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_platform_cards_status ON public.platform_cards(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_platform_cards_market ON public.platform_cards(card_market_id);
CREATE INDEX IF NOT EXISTS idx_platform_cards_category ON public.platform_cards(card_category, status);

COMMENT ON TABLE public.platform_cards IS '平台官方发行的卡牌库存';
COMMENT ON COLUMN public.platform_cards.initial_cost_price IS '进货价';
COMMENT ON COLUMN public.platform_cards.listing_price IS '初始上架价';
COMMENT ON COLUMN public.platform_cards.mark_price IS '绑定市场价系统的价格';

-- ============================================
-- Part 4: 预约/意向订单表（pre_orders）
-- ============================================
CREATE TABLE IF NOT EXISTS public.pre_orders (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_no TEXT NOT NULL UNIQUE,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    platform_card_id UUID REFERENCES public.platform_cards(id) ON DELETE RESTRICT NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    reserved_price NUMERIC(12,2) NOT NULL CHECK (reserved_price >= 0),
    shipping_fee NUMERIC(12,2) DEFAULT 0 CHECK (shipping_fee >= 0),
    platform_fee NUMERIC(12,2) DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL CHECK (total_amount >= 0),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'cancelled', 'expired', 'paid')),
    -- 支付预留字段
    payment_status TEXT NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid', 'paid', 'refunded', 'failed')),
    payment_method TEXT,
    transaction_id TEXT,
    paid_at TIMESTAMPTZ,
    -- 元信息
    notes TEXT,
    source TEXT NOT NULL DEFAULT 'platform_store' CHECK (source IN ('platform_store', 'marketplace', 'live')),
    expired_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '24 hours'),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pre_orders_user ON public.pre_orders(user_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_pre_orders_platform_card ON public.pre_orders(platform_card_id, status);
CREATE INDEX IF NOT EXISTS idx_pre_orders_expired ON public.pre_orders(status, expired_at) WHERE status = 'pending';

COMMENT ON TABLE public.pre_orders IS '无支付版本意向订单/预约购买';
COMMENT ON COLUMN public.pre_orders.reserved_price IS '下单时锁定的 mark_price';

-- ============================================
-- Part 5: 商品来源标记（card_market.source_type）
-- ============================================
ALTER TABLE public.card_market ADD COLUMN IF NOT EXISTS source_type TEXT DEFAULT 'user' CHECK (source_type IN ('platform', 'user'));
COMMENT ON COLUMN public.card_market.source_type IS 'platform=平台发行 | user=用户上传';

-- 现有记录默认为 user（不破坏历史数据）
UPDATE public.card_market SET source_type = 'user' WHERE source_type IS NULL;

-- 注意：如果后续要加 NOT NULL，先确保无 NULL 再执行：
-- ALTER TABLE public.card_market ALTER COLUMN source_type SET NOT NULL;

-- ============================================
-- Part 6: 平台发行操作日志（platform_issue_logs）
-- ============================================
CREATE TABLE IF NOT EXISTS public.platform_issue_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    admin_id UUID REFERENCES public.admins(id) ON DELETE SET NULL,
    action TEXT NOT NULL CHECK (action IN ('publish_card', 'update_card', 'cancel_pre_order', 'confirm_pre_order', 'adjust_stock', 'login', 'logout')),
    target_type TEXT NOT NULL CHECK (target_type IN ('platform_card', 'pre_order', 'admin', 'system')),
    target_id UUID,
    details JSONB DEFAULT '{}'::jsonb,
    ip_address TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_platform_issue_logs_admin ON public.platform_issue_logs(admin_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_platform_issue_logs_action ON public.platform_issue_logs(action, created_at DESC);

-- ============================================
-- Part 7: 触发器 — 自动更新 platform_cards.updated_at
-- ============================================
CREATE OR REPLACE FUNCTION public.trg_update_platform_cards_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_platform_cards_updated_at ON public.platform_cards;
CREATE TRIGGER trg_platform_cards_updated_at
    BEFORE UPDATE ON public.platform_cards
    FOR EACH ROW EXECUTE FUNCTION public.trg_update_platform_cards_timestamp();

CREATE OR REPLACE FUNCTION public.trg_update_pre_orders_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pre_orders_updated_at ON public.pre_orders;
CREATE TRIGGER trg_pre_orders_updated_at
    BEFORE UPDATE ON public.pre_orders
    FOR EACH ROW EXECUTE FUNCTION public.trg_update_pre_orders_timestamp();

-- ============================================
-- Part 8: RPC 函数 — 管理员登录
-- ============================================
CREATE OR REPLACE FUNCTION public.admin_login(
    p_username TEXT,
    p_password TEXT,
    p_session_duration_hours INTEGER DEFAULT 24
)
RETURNS TABLE(
    success BOOLEAN,
    admin_id UUID,
    username TEXT,
    role TEXT,
    display_name TEXT,
    session_token TEXT,
    expires_at TIMESTAMPTZ,
    error TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin public.admins%ROWTYPE;
    v_token TEXT;
    v_expires TIMESTAMPTZ;
BEGIN
    SELECT * INTO v_admin
    FROM public.admins
    WHERE admins.username = p_username AND admins.status = 'active';

    IF v_admin.id IS NULL THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ, '管理员账号不存在或已禁用'::TEXT;
        RETURN;
    END IF;

    IF v_admin.password_hash != extensions.crypt(p_password, v_admin.password_hash) THEN
        -- 记录失败日志
        INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
        VALUES (v_admin.id, 'login', 'admin', v_admin.id, jsonb_build_object('result', 'failed', 'reason', 'wrong_password'));

        RETURN QUERY SELECT false, NULL::UUID, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TEXT, NULL::TIMESTAMPTZ, '密码错误'::TEXT;
        RETURN;
    END IF;

    v_token := extensions.gen_random_uuid()::TEXT || '-' || EXTRACT(EPOCH FROM NOW())::TEXT;
    v_expires := NOW() + (p_session_duration_hours || ' hours')::INTERVAL;

    UPDATE public.admins
    SET session_token = v_token,
        token_expires_at = v_expires,
        last_login_at = NOW(),
        updated_at = NOW()
    WHERE id = v_admin.id;

    INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
    VALUES (v_admin.id, 'login', 'admin', v_admin.id, jsonb_build_object('result', 'success', 'expires_at', v_expires));

    RETURN QUERY SELECT
        true,
        v_admin.id,
        v_admin.username,
        v_admin.role,
        v_admin.display_name,
        v_token,
        v_expires,
        NULL::TEXT;
END;
$$;

-- 验证 admin token 的辅助函数
CREATE OR REPLACE FUNCTION public.verify_admin_token(p_token TEXT)
RETURNS TABLE(admin_id UUID, role TEXT, display_name TEXT, is_valid BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN QUERY
    SELECT a.id, a.role, a.display_name, true
    FROM public.admins a
    WHERE a.session_token = p_token
      AND a.token_expires_at > NOW()
      AND a.status = 'active';

    IF NOT FOUND THEN
        RETURN QUERY SELECT NULL::UUID, NULL::TEXT, NULL::TEXT, false;
    END IF;
END;
$$;

-- 管理员登出
CREATE OR REPLACE FUNCTION public.admin_logout(p_token TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin_id UUID;
BEGIN
    SELECT id INTO v_admin_id FROM public.admins WHERE session_token = p_token;
    IF v_admin_id IS NOT NULL THEN
        UPDATE public.admins SET session_token = NULL, token_expires_at = NULL WHERE id = v_admin_id;
        INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
        VALUES (v_admin_id, 'logout', 'admin', v_admin_id, '{}'::jsonb);
        RETURN true;
    END IF;
    RETURN false;
END;
$$;

-- ============================================
-- Part 9: RPC 函数 — 管理员发布平台卡牌
-- ============================================
CREATE OR REPLACE FUNCTION public.admin_publish_card(
    p_admin_token TEXT,
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
SET search_path = ''
AS $$
DECLARE
    v_admin public.admins%ROWTYPE;
    v_platform_card_id UUID;
    v_card_market_id UUID;
    v_final_price NUMERIC;
    v_mark_price NUMERIC;
BEGIN
    -- 验证管理员
    SELECT * INTO v_admin
    FROM public.admins
    WHERE session_token = p_admin_token
      AND token_expires_at > NOW()
      AND status = 'active';

    IF v_admin.id IS NULL THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC, '管理员未登录或 token 已过期'::TEXT;
        RETURN;
    END IF;

    -- 参数校验
    IF p_name IS NULL OR LENGTH(TRIM(p_name)) = 0 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC, '卡牌名称不能为空'::TEXT;
        RETURN;
    END IF;

    IF p_listing_price IS NULL OR p_listing_price < 0 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC, '上架价不能为负数'::TEXT;
        RETURN;
    END IF;

    IF p_stock_quantity IS NULL OR p_stock_quantity < 0 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::UUID, NULL::NUMERIC, NULL::NUMERIC, '库存数量不能为负数'::TEXT;
        RETURN;
    END IF;

    -- 创建 card_market 记录（接入 pricing engine）
    -- listing_price 作为 market_price 输入，source_type = platform
    INSERT INTO public.card_market (
        card_name, series, rarity, card_category, market,
        market_price, market_source,
        ai_estimate_price, ai_model,
        source_type
    ) VALUES (
        p_name, COALESCE(p_set_name, ''), COALESCE(p_rarity, 'N'), COALESCE(p_card_category, 'other'), 'CN',
        p_listing_price, 'platform_issue',
        p_listing_price, 'platform_admin',
        'platform'
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

    -- 读取 pricing engine 计算后的 final_price / mark_price
    SELECT cm.final_price, cm.mark_price
    INTO v_final_price, v_mark_price
    FROM public.card_market cm
    WHERE cm.id = v_card_market_id;

    -- 创建 platform_cards 记录
    INSERT INTO public.platform_cards (
        admin_id, name, name_en, set_name, card_image_url, images, thumbnail_url,
        description, card_category, rarity, condition,
        initial_cost_price, listing_price, mark_price,
        stock_quantity, status,
        source, card_market_id,
        platform_fee_pct, shipping_fee
    ) VALUES (
        v_admin.id, p_name, NULL, p_set_name, p_card_image_url, COALESCE(p_images, '{}'), p_thumbnail_url,
        p_description, p_card_category, p_rarity, p_condition,
        COALESCE(p_initial_cost_price, 0), p_listing_price, v_mark_price,
        p_stock_quantity, CASE WHEN p_stock_quantity > 0 THEN 'active' ELSE 'sold_out' END,
        'platform', v_card_market_id,
        COALESCE(p_platform_fee_pct, 0), COALESCE(p_shipping_fee, 0)
    )
    RETURNING id INTO v_platform_card_id;

    -- 记录日志
    INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
    VALUES (v_admin.id, 'publish_card', 'platform_card', v_platform_card_id, jsonb_build_object(
        'name', p_name,
        'listing_price', p_listing_price,
        'stock', p_stock_quantity,
        'card_market_id', v_card_market_id
    ));

    RETURN QUERY SELECT true, v_platform_card_id, v_card_market_id, v_final_price, v_mark_price, NULL::TEXT;
END;
$$;

-- ============================================
-- Part 10: RPC 函数 — 更新平台卡牌（库存/价格/状态）
-- ============================================
CREATE OR REPLACE FUNCTION public.admin_update_platform_card(
    p_admin_token TEXT,
    p_platform_card_id UUID,
    p_status TEXT DEFAULT NULL,
    p_stock_quantity INTEGER DEFAULT NULL,
    p_listing_price NUMERIC DEFAULT NULL,
    p_mark_price NUMERIC DEFAULT NULL,
    p_description TEXT DEFAULT NULL,
    p_card_image_url TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, error TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin public.admins%ROWTYPE;
    v_card public.platform_cards%ROWTYPE;
BEGIN
    SELECT * INTO v_admin
    FROM public.admins
    WHERE session_token = p_admin_token
      AND token_expires_at > NOW()
      AND status = 'active';

    IF v_admin.id IS NULL THEN
        RETURN QUERY SELECT false, '管理员未登录或 token 已过期'::TEXT;
        RETURN;
    END IF;

    SELECT * INTO v_card
    FROM public.platform_cards
    WHERE id = p_platform_card_id;

    IF v_card.id IS NULL THEN
        RETURN QUERY SELECT false, '平台卡牌不存在'::TEXT;
        RETURN;
    END IF;

    UPDATE public.platform_cards
    SET status = COALESCE(p_status, status),
        stock_quantity = COALESCE(p_stock_quantity, stock_quantity),
        listing_price = COALESCE(p_listing_price, listing_price),
        mark_price = COALESCE(p_mark_price, mark_price),
        description = COALESCE(p_description, description),
        card_image_url = COALESCE(p_card_image_url, card_image_url),
        updated_at = NOW()
    WHERE id = p_platform_card_id;

    -- 同步更新 card_market 价格（避免破坏 final_price 规则）
    IF p_listing_price IS NOT NULL AND v_card.card_market_id IS NOT NULL THEN
        UPDATE public.card_market
        SET market_price = p_listing_price,
            market_source = 'platform_issue_updated',
            updated_at = NOW()
        WHERE id = v_card.card_market_id;
    END IF;

    INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
    VALUES (v_admin.id, 'update_card', 'platform_card', p_platform_card_id, jsonb_build_object(
        'status', p_status,
        'stock_quantity', p_stock_quantity,
        'listing_price', p_listing_price
    ));

    RETURN QUERY SELECT true, NULL::TEXT;
END;
$$;

-- ============================================
-- Part 11: RPC 函数 — 用户预约购买
-- ============================================
CREATE OR REPLACE FUNCTION public.create_pre_order(
    p_user_id UUID,
    p_platform_card_id UUID,
    p_quantity INTEGER DEFAULT 1,
    p_source TEXT DEFAULT 'platform_store',
    p_notes TEXT DEFAULT NULL
)
RETURNS TABLE(
    success BOOLEAN,
    pre_order_id UUID,
    order_no TEXT,
    reserved_price NUMERIC,
    total_amount NUMERIC,
    status TEXT,
    error TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_card public.platform_cards%ROWTYPE;
    v_mark_price NUMERIC;
    v_total NUMERIC;
    v_order_no TEXT;
    v_pre_order_id UUID;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT, '数量必须大于0'::TEXT;
        RETURN;
    END IF;

    -- 锁定平台卡牌行
    SELECT * INTO v_card
    FROM public.platform_cards
    WHERE id = p_platform_card_id
    FOR UPDATE;

    IF v_card.id IS NULL THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT, '卡牌不存在'::TEXT;
        RETURN;
    END IF;

    IF v_card.status != 'active' THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT, '该卡牌当前不可预约'::TEXT;
        RETURN;
    END IF;

    IF v_card.available_quantity < p_quantity THEN
        RETURN QUERY SELECT false, NULL::UUID, NULL::TEXT, NULL::NUMERIC, NULL::NUMERIC, NULL::TEXT, '库存不足'::TEXT;
        RETURN;
    END IF;

    -- 获取当前 mark_price（优先用 card_market.mark_price，否则用 listing_price）
    SELECT COALESCE(cm.mark_price, cm.final_price, v_card.listing_price)
    INTO v_mark_price
    FROM public.card_market cm
    WHERE cm.id = v_card.card_market_id;

    IF v_mark_price IS NULL THEN
        v_mark_price := v_card.listing_price;
    END IF;

    v_total := (v_mark_price * p_quantity) + (v_card.shipping_fee * p_quantity);
    v_order_no := 'PO-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || UPPER(SUBSTRING(extensions.gen_random_uuid()::TEXT, 1, 8));

    -- 扣减可售库存（增加 reserved_quantity）
    UPDATE public.platform_cards
    SET reserved_quantity = reserved_quantity + p_quantity,
        updated_at = NOW()
    WHERE id = p_platform_card_id;

    -- 创建意向订单
    INSERT INTO public.pre_orders (
        order_no, user_id, platform_card_id, quantity,
        reserved_price, shipping_fee, platform_fee, total_amount,
        status, payment_status, notes, source, expired_at
    ) VALUES (
        v_order_no, p_user_id, p_platform_card_id, p_quantity,
        v_mark_price, v_card.shipping_fee, 0, v_total,
        'pending', 'unpaid', p_notes, p_source, NOW() + INTERVAL '24 hours'
    )
    RETURNING id INTO v_pre_order_id;

    -- 更新 platform_cards 状态
    UPDATE public.platform_cards
    SET status = CASE WHEN available_quantity <= 0 THEN 'sold_out' ELSE platform_cards.status END
    WHERE id = p_platform_card_id;

    RETURN QUERY SELECT true, v_pre_order_id, v_order_no, v_mark_price, v_total, 'pending'::TEXT, NULL::TEXT;
END;
$$;

-- ============================================
-- Part 12: RPC 函数 — 取消预约订单
-- ============================================
CREATE OR REPLACE FUNCTION public.cancel_pre_order(
    p_user_id UUID,
    p_pre_order_id UUID
)
RETURNS TABLE(success BOOLEAN, error TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.pre_orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order
    FROM public.pre_orders
    WHERE id = p_pre_order_id
    FOR UPDATE;

    IF v_order.id IS NULL THEN
        RETURN QUERY SELECT false, '订单不存在'::TEXT;
        RETURN;
    END IF;

    IF v_order.user_id != p_user_id THEN
        RETURN QUERY SELECT false, '无权操作该订单'::TEXT;
        RETURN;
    END IF;

    IF v_order.status NOT IN ('pending', 'confirmed') THEN
        RETURN QUERY SELECT false, '订单状态不允许取消'::TEXT;
        RETURN;
    END IF;

    -- 释放库存
    UPDATE public.platform_cards
    SET reserved_quantity = GREATEST(reserved_quantity - v_order.quantity, 0),
        status = CASE WHEN platform_cards.status = 'sold_out' THEN 'active' ELSE platform_cards.status END,
        updated_at = NOW()
    WHERE id = v_order.platform_card_id;

    UPDATE public.pre_orders
    SET status = 'cancelled',
        payment_status = CASE WHEN payment_status = 'paid' THEN 'refunded' ELSE payment_status END,
        updated_at = NOW()
    WHERE id = p_pre_order_id;

    RETURN QUERY SELECT true, NULL::TEXT;
END;
$$;

-- ============================================
-- Part 13: RPC 函数 — 管理员确认/标记已支付（预留支付接口）
-- ============================================
CREATE OR REPLACE FUNCTION public.admin_confirm_pre_order(
    p_admin_token TEXT,
    p_pre_order_id UUID,
    p_payment_method TEXT DEFAULT 'mock_payment',
    p_transaction_id TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, error TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin public.admins%ROWTYPE;
    v_order public.pre_orders%ROWTYPE;
    v_final_txn TEXT;
BEGIN
    SELECT * INTO v_admin
    FROM public.admins
    WHERE session_token = p_admin_token
      AND token_expires_at > NOW()
      AND status = 'active';

    IF v_admin.id IS NULL THEN
        RETURN QUERY SELECT false, '管理员未登录或 token 已过期'::TEXT;
        RETURN;
    END IF;

    SELECT * INTO v_order
    FROM public.pre_orders
    WHERE id = p_pre_order_id
    FOR UPDATE;

    IF v_order.id IS NULL THEN
        RETURN QUERY SELECT false, '订单不存在'::TEXT;
        RETURN;
    END IF;

    IF v_order.status != 'pending' THEN
        RETURN QUERY SELECT false, '订单状态不允许确认'::TEXT;
        RETURN;
    END IF;

    v_final_txn := COALESCE(p_transaction_id, 'MOCK-' || extensions.gen_random_uuid()::TEXT);

    -- 将 reserved 转为 sold
    UPDATE public.platform_cards
    SET reserved_quantity = GREATEST(reserved_quantity - v_order.quantity, 0),
        sold_quantity = sold_quantity + v_order.quantity,
        updated_at = NOW()
    WHERE id = v_order.platform_card_id;

    UPDATE public.pre_orders
    SET status = 'paid',
        payment_status = 'paid',
        payment_method = p_payment_method,
        transaction_id = v_final_txn,
        paid_at = NOW(),
        updated_at = NOW()
    WHERE id = p_pre_order_id;

    INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
    VALUES (v_admin.id, 'confirm_pre_order', 'pre_order', p_pre_order_id, jsonb_build_object(
        'user_id', v_order.user_id,
        'platform_card_id', v_order.platform_card_id,
        'quantity', v_order.quantity,
        'total_amount', v_order.total_amount,
        'transaction_id', v_final_txn
    ));

    RETURN QUERY SELECT true, NULL::TEXT;
END;
$$;

-- ============================================
-- Part 14: RPC 函数 — 刷新平台卡牌的 mark_price
-- ============================================
CREATE OR REPLACE FUNCTION public.refresh_platform_card_prices(p_platform_card_id UUID DEFAULT NULL)
RETURNS TABLE(
    platform_card_id UUID,
    old_mark_price NUMERIC,
    new_mark_price NUMERIC,
    final_price NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN QUERY
    WITH updated AS (
        UPDATE public.card_market cm
        SET updated_at = NOW()
        FROM public.platform_cards pc
        WHERE pc.card_market_id = cm.id
          AND (p_platform_card_id IS NULL OR pc.id = p_platform_card_id)
          AND cm.source_type = 'platform'
        RETURNING pc.id AS pc_id, pc.mark_price AS old_mark, cm.mark_price AS new_mark, cm.final_price
    )
    UPDATE public.platform_cards pc
    SET mark_price = u.new_mark,
        updated_at = NOW()
    FROM updated u
    WHERE pc.id = u.pc_id
    RETURNING pc.id, u.old_mark, pc.mark_price, u.final_price;
END;
$$;

-- ============================================
-- Part 15: RPC 函数 — 获取平台卡牌列表（含库存/价格）
-- ============================================
CREATE OR REPLACE FUNCTION public.get_platform_card_list(
    p_status TEXT DEFAULT 'active',
    p_card_category TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    id UUID,
    name TEXT,
    name_en TEXT,
    set_name TEXT,
    card_image_url TEXT,
    thumbnail_url TEXT,
    description TEXT,
    card_category TEXT,
    rarity TEXT,
    condition TEXT,
    listing_price NUMERIC,
    mark_price NUMERIC,
    final_price NUMERIC,
    stock_quantity INTEGER,
    reserved_quantity INTEGER,
    sold_quantity INTEGER,
    available_quantity INTEGER,
    status TEXT,
    source_type TEXT,
    price_source TEXT,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN QUERY
    SELECT
        pc.id,
        pc.name,
        pc.name_en,
        pc.set_name,
        pc.card_image_url,
        pc.thumbnail_url,
        pc.description,
        pc.card_category,
        pc.rarity,
        pc.condition,
        pc.listing_price,
        pc.mark_price,
        cm.final_price,
        pc.stock_quantity,
        pc.reserved_quantity,
        pc.sold_quantity,
        pc.available_quantity,
        pc.status,
        cm.source_type,
        cm.price_source,
        pc.created_at
    FROM public.platform_cards pc
    LEFT JOIN public.card_market cm ON cm.id = pc.card_market_id
    WHERE (p_status IS NULL OR pc.status = p_status)
      AND (p_card_category IS NULL OR pc.card_category = p_card_category)
    ORDER BY pc.created_at DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$;

-- ============================================
-- Part 16: RPC 函数 — 获取用户预约订单列表
-- ============================================
CREATE OR REPLACE FUNCTION public.get_user_pre_orders(p_user_id UUID)
RETURNS TABLE(
    id UUID,
    order_no TEXT,
    platform_card_id UUID,
    card_name TEXT,
    card_image_url TEXT,
    quantity INTEGER,
    reserved_price NUMERIC,
    total_amount NUMERIC,
    status TEXT,
    payment_status TEXT,
    source TEXT,
    expired_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    RETURN QUERY
    SELECT
        po.id,
        po.order_no,
        po.platform_card_id,
        pc.name AS card_name,
        pc.card_image_url,
        po.quantity,
        po.reserved_price,
        po.total_amount,
        po.status,
        po.payment_status,
        po.source,
        po.expired_at,
        po.created_at
    FROM public.pre_orders po
    JOIN public.platform_cards pc ON pc.id = po.platform_card_id
    WHERE po.user_id = p_user_id
    ORDER BY po.created_at DESC;
END;
$$;

-- ============================================
-- Part 17: 视图 — 平台商店商品列表
-- ============================================
CREATE OR REPLACE VIEW public.platform_store_list AS
SELECT
    pc.id,
    pc.name,
    pc.name_en,
    pc.set_name,
    pc.card_image_url,
    pc.thumbnail_url,
    pc.description,
    pc.card_category,
    pc.rarity,
    pc.condition,
    pc.listing_price,
    pc.mark_price,
    cm.final_price,
    cm.price_source,
    pc.stock_quantity,
    pc.reserved_quantity,
    pc.sold_quantity,
    pc.available_quantity,
    pc.status,
    pc.shipping_fee,
    pc.platform_fee_pct,
    pc.created_at,
    cm.source_type,
    cm.activity_score,
    cm.market_state
FROM public.platform_cards pc
LEFT JOIN public.card_market cm ON cm.id = pc.card_market_id
WHERE pc.status IN ('active', 'sold_out');

-- ============================================
-- Part 18: 权限与 RLS
-- ============================================
-- admins 表：仅 service_role 可读写（前端通过 RPC 访问）
ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admins_service_all" ON public.admins;
CREATE POLICY "admins_service_all" ON public.admins
    FOR ALL USING (current_user = 'supabase_admin' OR current_user LIKE 'service_role%')
    WITH CHECK (current_user = 'supabase_admin' OR current_user LIKE 'service_role%');

-- platform_cards：所有人可读，只有 service_role/admin RPC 可写
ALTER TABLE public.platform_cards ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "platform_cards_select_public" ON public.platform_cards;
CREATE POLICY "platform_cards_select_public" ON public.platform_cards
    FOR SELECT USING (true);

DROP POLICY IF EXISTS "platform_cards_write_service" ON public.platform_cards;
CREATE POLICY "platform_cards_write_service" ON public.platform_cards
    FOR ALL USING (current_user = 'supabase_admin' OR current_user LIKE 'service_role%')
    WITH CHECK (current_user = 'supabase_admin' OR current_user LIKE 'service_role%');

-- pre_orders：用户只能看自己的
ALTER TABLE public.pre_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pre_orders_select_owner" ON public.pre_orders;
CREATE POLICY "pre_orders_select_owner" ON public.pre_orders
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "pre_orders_insert_owner" ON public.pre_orders;
CREATE POLICY "pre_orders_insert_owner" ON public.pre_orders
    FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "pre_orders_update_owner" ON public.pre_orders;
CREATE POLICY "pre_orders_update_owner" ON public.pre_orders
    FOR UPDATE USING (auth.uid() = user_id);

-- platform_issue_logs：仅 service_role 可读
ALTER TABLE public.platform_issue_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "platform_issue_logs_service" ON public.platform_issue_logs;
CREATE POLICY "platform_issue_logs_service" ON public.platform_issue_logs
    FOR ALL USING (current_user = 'supabase_admin' OR current_user LIKE 'service_role%')
    WITH CHECK (current_user = 'supabase_admin' OR current_user LIKE 'service_role%');

-- 视图权限
GRANT SELECT ON public.platform_store_list TO authenticated, anon;

-- 函数执行权限
GRANT EXECUTE ON FUNCTION public.admin_login TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_logout TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_admin_token TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_publish_card TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_platform_card TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_pre_order TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_pre_order TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_confirm_pre_order TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_platform_card_prices TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_platform_card_list TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_pre_orders TO authenticated;
