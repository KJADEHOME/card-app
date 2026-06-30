-- ============================================================
-- CardRealm MVP Phase 5: 商城系统 (Shop + Products + Orders)
-- ============================================================

-- ============================================================
-- 一、商品表
-- ============================================================
CREATE TABLE IF NOT EXISTS public.products (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT DEFAULT '',
    price NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    original_price NUMERIC(12,2),
    image_url TEXT DEFAULT '',
    images TEXT[] DEFAULT '{}',
    stock INTEGER NOT NULL DEFAULT 0 CHECK (stock >= 0),
    sold_count INTEGER DEFAULT 0,
    category TEXT NOT NULL DEFAULT 'card' CHECK (category IN ('card','pack','merch','live','supply')),
    source TEXT DEFAULT 'manual' CHECK (source IN ('tiktok','manual','system')),
    live_room_id TEXT,
    live_url TEXT,
    status TEXT DEFAULT 'active' CHECK (status IN ('active','inactive','sold_out')),
    tags TEXT[] DEFAULT '{}',
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_products_category ON public.products(category, status);
CREATE INDEX IF NOT EXISTS idx_products_source ON public.products(source);
CREATE INDEX IF NOT EXISTS idx_products_status ON public.products(status);
CREATE INDEX IF NOT EXISTS idx_products_sort ON public.products(sort_order, created_at DESC);

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

-- 所有人可读
CREATE POLICY "products_select" ON public.products FOR SELECT USING (status = 'active');
-- 仅 authenticated 可读全部
CREATE POLICY "products_select_all" ON public.products FOR SELECT TO authenticated USING (true);

-- ============================================================
-- 二、库存变动日志
-- ============================================================
CREATE TABLE IF NOT EXISTS public.stock_log (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    product_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
    order_id UUID,
    change_amount INTEGER NOT NULL,
    reason TEXT DEFAULT 'order' CHECK (reason IN ('order','restock','manual','cancel')),
    note TEXT DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stock_log_product ON public.stock_log(product_id, created_at DESC);

ALTER TABLE public.stock_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_log FROM authenticated, anon;

-- ============================================================
-- 三、orders 表增强（shop 兼容）
-- ============================================================
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS product_id UUID REFERENCES public.products(id) ON DELETE SET NULL;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS quantity INTEGER DEFAULT 1 CHECK (quantity > 0);
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS order_source TEXT DEFAULT 'marketplace' CHECK (order_source IN ('marketplace','shop','live'));
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS idempotency_key TEXT;

CREATE INDEX IF NOT EXISTS idx_orders_product ON public.orders(product_id);
CREATE INDEX IF NOT EXISTS idx_orders_source ON public.orders(order_source);

-- ============================================================
-- 四、RPC: 商城下单（原子操作 + 库存锁）
-- ============================================================
CREATE OR REPLACE FUNCTION create_shop_order(
    p_user_id UUID,
    p_product_id UUID,
    p_quantity INTEGER DEFAULT 1,
    p_currency TEXT DEFAULT 'CNY',
    p_source TEXT DEFAULT 'shop',
    p_idempotency_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_product products%ROWTYPE;
    v_total_price NUMERIC(12,2);
    v_order_no TEXT;
    v_order_id UUID;
    v_order_seq INTEGER;
    v_platform_fee NUMERIC(12,2);
    v_platform_fee_pct NUMERIC := 0.05;
BEGIN
    -- 幂等检查
    IF p_idempotency_key IS NOT NULL THEN
        SELECT id INTO v_order_id FROM public.orders
        WHERE buyer_id = p_user_id AND idempotency_key = p_idempotency_key
        LIMIT 1;
        IF FOUND THEN
            RETURN jsonb_build_object(
                'success', true,
                'order_id', v_order_id,
                'message', '订单已存在（幂等）'
            );
        END IF;
    END IF;

    -- 锁定商品行（防超卖）
    SELECT * INTO v_product FROM public.products
    WHERE id = p_product_id AND status = 'active'
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '商品不存在或已下架');
    END IF;

    IF v_product.stock < p_quantity THEN
        RETURN jsonb_build_object(
            'success', false, 'error', '库存不足',
            'stock', v_product.stock, 'requested', p_quantity
        );
    END IF;

    -- 计算金额
    v_total_price := v_product.price * p_quantity;
    v_platform_fee := ROUND(v_total_price * v_platform_fee_pct, 2);

    -- 生成订单号
    SELECT COALESCE(MAX(NULLIF(regexp_replace(order_no, '[^0-9]', '', 'g'), '')::INTEGER), 0) + 1
    INTO v_order_seq FROM public.orders
    WHERE created_at::DATE = CURRENT_DATE;

    v_order_no := 'SHOP' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || LPAD(v_order_seq::TEXT, 4, '0');

    -- 创建订单
    INSERT INTO public.orders (
        order_no, buyer_id, product_id, quantity,
        item_price, total_amount, platform_fee, currency,
        status, order_source, idempotency_key
    ) VALUES (
        v_order_no, p_user_id, p_product_id, p_quantity,
        v_product.price, v_total_price, v_platform_fee, p_currency,
        'pending', p_source, p_idempotency_key
    ) RETURNING id INTO v_order_id;

    -- 扣减库存
    UPDATE public.products SET
        stock = stock - p_quantity,
        sold_count = COALESCE(sold_count, 0) + p_quantity,
        updated_at = NOW(),
        status = CASE WHEN stock - p_quantity <= 0 THEN 'sold_out' ELSE status END
    WHERE id = p_product_id;

    -- 记录库存变动
    INSERT INTO public.stock_log (product_id, order_id, change_amount, reason)
    VALUES (p_product_id, v_order_id, -p_quantity, 'order');

    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order_id,
        'order_no', v_order_no,
        'total_amount', v_total_price,
        'platform_fee', v_platform_fee,
        'quantity', p_quantity,
        'stock_remaining', v_product.stock - p_quantity
    );
END;
$$;

-- ============================================================
-- RPC: 模拟支付（状态 pending → paid）
-- ============================================================
CREATE OR REPLACE FUNCTION pay_shop_order(
    p_order_id UUID,
    p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order orders%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM public.orders
    WHERE id = p_order_id AND buyer_id = p_user_id AND order_source IN ('shop','live')
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    IF v_order.status != 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', '订单状态不允许支付: ' || v_order.status);
    END IF;

    UPDATE public.orders SET
        status = 'paid',
        paid_at = NOW(),
        updated_at = NOW()
    WHERE id = p_order_id;

    RETURN jsonb_build_object(
        'success', true,
        'order_id', p_order_id,
        'status', 'paid'
    );
END;
$$;

-- ============================================================
-- RPC: 取消商城订单并释放库存
-- ============================================================
CREATE OR REPLACE FUNCTION release_shop_order_stock(
    p_order_id UUID,
    p_product_id UUID,
    p_quantity INTEGER DEFAULT 1
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    UPDATE public.products SET
        stock = stock + p_quantity,
        updated_at = NOW(),
        status = CASE WHEN stock + p_quantity > 0 THEN 'active' ELSE status END
    WHERE id = p_product_id;

    INSERT INTO public.stock_log (product_id, order_id, change_amount, reason, note)
    VALUES (p_product_id, p_order_id, p_quantity, 'cancel', '订单取消，释放库存');

    RETURN jsonb_build_object('success', true);
END;
$$;

-- ============================================================
-- RPC: 获取商品列表（支持分类筛选）
-- ============================================================
CREATE OR REPLACE FUNCTION get_shop_products(
    p_category TEXT DEFAULT NULL,
    p_source TEXT DEFAULT NULL,
    p_search TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    id UUID,
    title TEXT,
    description TEXT,
    price NUMERIC(12,2),
    original_price NUMERIC(12,2),
    image_url TEXT,
    images TEXT[],
    stock INTEGER,
    sold_count INTEGER,
    category TEXT,
    source TEXT,
    live_room_id TEXT,
    live_url TEXT,
    status TEXT,
    tags TEXT[],
    created_at TIMESTAMPTZ,
    total_count BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        p.id, p.title, p.description, p.price, p.original_price,
        p.image_url, p.images, p.stock, p.sold_count,
        p.category, p.source, p.live_room_id, p.live_url,
        p.status, p.tags, p.created_at,
        COUNT(*) OVER() AS total_count
    FROM public.products p
    WHERE p.status = 'active'
      AND (p_category IS NULL OR p.category = p_category)
      AND (p_source IS NULL OR p.source = p_source)
      AND (p_search IS NULL OR p.title ILIKE '%' || p_search || '%')
    ORDER BY p.sort_order, p.created_at DESC
    LIMIT p_limit OFFSET p_offset;
$$;

-- ============================================================
-- 五、种子商品数据（演示用）
-- ============================================================
INSERT INTO public.products (title, description, price, original_price, stock, category, source, image_url, tags, sort_order) VALUES
('宝可梦 151 补充包（日版）', '宝可梦151系列补充包，每包含6张随机卡牌，有机会获得稀有全息卡', 39.90, 45.00, 200, 'pack', 'manual', 'https://images.unsplash.com/photo-1613771404721-1f92d285be4a?w=400', ARRAY['热门','Pokemon','日版'], 1),
('航海王卡牌 起始卡组', 'ONE PIECE CARD GAME 官方起始卡组，包含规则书及50张卡牌', 88.00, 108.00, 150, 'pack', 'manual', 'https://images.unsplash.com/photo-1608889825103-eb5ed706fc64?w=400', ARRAY['One Piece','新手推荐'], 2),
('游戏王 25周年纪念套装', '游戏王OCG 25周年纪念版，含限定闪卡+卡盒+卡套', 299.00, 358.00, 50, 'merch', 'manual', 'https://images.unsplash.com/photo-1611523658822-385aa0087cb0?w=400', ARRAY['限量','25周年','Yu-Gi-Oh'], 3),
('卡牌收纳册（9格）', '专业卡牌收纳册，9格侧插页，可容纳360张卡牌', 58.00, 69.00, 300, 'supply', 'manual', 'https://images.unsplash.com/photo-1607344645869-009c320b63e4?w=400', ARRAY['收纳','必备'], 4),
('卡牌透明保护套（100枚）', '高透防刮保护套，游戏王/宝可梦/万智牌通用尺寸', 19.90, 25.00, 500, 'supply', 'manual', 'https://images.unsplash.com/photo-1560800452-4cc1c19c6f2c?w=400', ARRAY['保护套','消耗品'], 5),
('万智牌 兄弟之战 补充包', 'Magic: The Gathering Brothers'' War 补充包，每包15张', 35.00, 40.00, 180, 'pack', 'manual', 'https://images.unsplash.com/photo-1596462502278-27bfdc76c06c?w=400', ARRAY['MTG','热门'], 6),
('决斗大师 Duel Masters 卡盒', '限定版决斗卡盒，可装80张套牌卡+骰子配件', 128.00, 158.00, 80, 'merch', 'manual', 'https://images.unsplash.com/photo-1577137257362-10e4c4f67f8f?w=400', ARRAY['卡盒','限定'], 7),
('宝可梦 天地万物 扩充包', '宝可梦 朱&紫 天地万物系列扩充包，收录全新宝可梦V', 42.00, 48.00, 120, 'pack', 'manual', 'https://images.unsplash.com/photo-1548630826-2ec01a41f48f?w=400', ARRAY['Pokemon','朱紫','新系列'], 8)
ON CONFLICT DO NOTHING;

-- ============================================================
-- 六、RPC: 获取订单列表（支持商城 + 市场）
-- ============================================================
CREATE OR REPLACE FUNCTION get_user_orders(
    p_user_id UUID,
    p_role TEXT DEFAULT 'buyer',  -- 'buyer' | 'seller'
    p_status TEXT DEFAULT NULL,
    p_source TEXT DEFAULT NULL,   -- 'shop' | 'marketplace' | NULL = all
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE(
    id UUID,
    order_no TEXT,
    buyer_id UUID,
    seller_id UUID,
    product_id UUID,
    consignment_id UUID,
    item_price NUMERIC(12,2),
    shipping_fee NUMERIC(12,2),
    platform_fee NUMERIC(12,2),
    total_amount NUMERIC(12,2),
    seller_earnings NUMERIC(12,2),
    quantity INTEGER,
    status TEXT,
    order_source TEXT,
    product_title TEXT,
    product_image TEXT,
    card_name TEXT,
    card_image TEXT,
    buyer_name TEXT,
    seller_name TEXT,
    created_at TIMESTAMPTZ,
    total_count BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        o.id, o.order_no, o.buyer_id, o.seller_id,
        o.product_id, o.consignment_id,
        o.item_price, o.shipping_fee, o.platform_fee,
        o.total_amount, o.seller_earnings,
        COALESCE(o.quantity, 1),
        o.status, COALESCE(o.order_source, 'marketplace'),
        p.title AS product_title, p.image_url AS product_image,
        c.card_name, c.card_image,
        bu.raw_user_meta_data->>'full_name' AS buyer_name,
        su.raw_user_meta_data->>'full_name' AS seller_name,
        o.created_at,
        COUNT(*) OVER() AS total_count
    FROM public.orders o
    LEFT JOIN public.products p ON o.product_id = p.id
    LEFT JOIN public.consignments c ON o.consignment_id = c.id
    LEFT JOIN auth.users bu ON o.buyer_id = bu.id
    LEFT JOIN auth.users su ON o.seller_id = su.id
    WHERE (
        (p_role = 'buyer' AND o.buyer_id = p_user_id)
        OR (p_role = 'seller' AND o.seller_id = p_user_id)
    )
      AND (p_status IS NULL OR o.status = p_status)
      AND (p_source IS NULL OR COALESCE(o.order_source, 'marketplace') = p_source)
    ORDER BY o.created_at DESC
    LIMIT p_limit OFFSET p_offset;
$$;

COMMENT ON TABLE public.products IS '官方商城商品表（卡包/周边/耗材）';
COMMENT ON TABLE public.stock_log IS '库存变动日志';
COMMENT ON FUNCTION create_shop_order IS '原子下单：锁库存 → 创建订单 → 扣库存 → 记录日志';
COMMENT ON FUNCTION pay_shop_order IS '模拟支付：pending → paid';
COMMENT ON FUNCTION get_shop_products IS '商品列表查询（分类/来源/搜索）';
COMMENT ON FUNCTION get_user_orders IS '统一订单查询（商城+市场）';
