-- ============================================================
-- 0012: 交易库存联动 & 原子交易 RPC
-- CardRealm MVP第三阶段 —— 上架→购买→成交 完整闭环
-- ============================================================

-- 1. consignments 增加库存联动字段
ALTER TABLE public.consignments 
  ADD COLUMN IF NOT EXISTS collection_id UUID REFERENCES public.user_collections(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS quantity INTEGER DEFAULT 1 CHECK (quantity > 0);

COMMENT ON COLUMN public.consignments.collection_id IS '关联的 user_collections 记录（从库存上架则非空）';
COMMENT ON COLUMN public.consignments.quantity IS '上架数量';

-- 2. user_collections 增加冻结库存字段
ALTER TABLE public.user_collections 
  ADD COLUMN IF NOT EXISTS reserved_quantity INTEGER DEFAULT 0 CHECK (reserved_quantity >= 0);

COMMENT ON COLUMN public.user_collections.reserved_quantity IS '已上架冻结数量（不可重复上架）';

-- 3. 来源字段（之前0010迁移已添加source字段，确认兼容）
ALTER TABLE public.user_collections 
  ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'MANUAL' 
  CHECK (source IN ('AI_SCAN', 'MANUAL', 'IMPORT', 'TRADE', 'PURCHASE'));

-- ============================================================
-- RPC 1: 从库存上架卡牌（原子操作）
-- 冻结库存 → 创建寄售单
-- ============================================================
CREATE OR REPLACE FUNCTION create_consignment_from_collection(
    p_user_id UUID,
    p_collection_id UUID,
    p_asking_price NUMERIC,
    p_shipping_fee NUMERIC DEFAULT 0,
    p_description TEXT DEFAULT '',
    p_tags TEXT[] DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
    v_collection RECORD;
    v_available_qty INTEGER;
    v_consignment_id UUID;
    v_platform_fee NUMERIC;
    v_seller_earnings NUMERIC;
    v_platform_fee_pct NUMERIC := 8.00;
BEGIN
    -- 获取平台费率
    SELECT COALESCE(NULLIF(value, ''), '8')::NUMERIC INTO v_platform_fee_pct 
    FROM public.platform_config WHERE key = 'fee_transaction_pct';
    IF v_platform_fee_pct IS NULL THEN v_platform_fee_pct := 8.00; END IF;

    -- 锁定库存记录
    SELECT * INTO v_collection 
    FROM public.user_collections 
    WHERE id = p_collection_id AND user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '库存记录不存在或不属于你');
    END IF;

    -- 计算可用数量
    v_available_qty := COALESCE(v_collection.quantity, 0) - COALESCE(v_collection.reserved_quantity, 0);
    IF v_available_qty <= 0 THEN
        RETURN json_build_object('success', false, 'error', '该卡牌库存不足，无法上架');
    END IF;

    -- 冻结1张
    UPDATE public.user_collections
    SET reserved_quantity = COALESCE(reserved_quantity, 0) + 1,
        updated_at = NOW()
    WHERE id = p_collection_id;

    -- 计算手续费
    v_platform_fee := ROUND(p_asking_price * v_platform_fee_pct / 100, 2);
    v_seller_earnings := p_asking_price - v_platform_fee;

    -- 创建寄售单
    INSERT INTO public.consignments (
        seller_id, collection_id, quantity,
        card_name, card_name_en, card_image, series, rarity, card_category, condition,
        asking_price, currency,
        platform_fee_pct, platform_fee, seller_earnings,
        shipping_fee, description, tags,
        status
    ) VALUES (
        p_user_id, p_collection_id, 1,
        v_collection.card_name, v_collection.card_name_en, v_collection.card_image,
        v_collection.series, v_collection.rarity, v_collection.card_category, v_collection.condition,
        p_asking_price, 'CNY',
        v_platform_fee_pct, v_platform_fee, v_seller_earnings,
        p_shipping_fee, p_description, p_tags,
        'active'
    ) RETURNING id INTO v_consignment_id;

    RETURN json_build_object(
        'success', true,
        'consignment_id', v_consignment_id,
        'platform_fee', v_platform_fee,
        'seller_earnings', v_seller_earnings,
        'fee_pct', v_platform_fee_pct
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 2: 购买寄售卡牌（原子交易核心）
-- 扣款 → 改状态 → 转移库存 → 创建订单 → 记录流水
-- ============================================================
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
    -- 1. 锁定寄售单，检查状态
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

    -- 2. 获取平台费率
    v_fee_pct := COALESCE(v_consign.platform_fee_pct, 8.00);
    v_total_amount := v_consign.asking_price + COALESCE(v_consign.shipping_fee, 0);
    v_platform_fee := ROUND(v_consign.asking_price * v_fee_pct / 100, 2);
    v_seller_earnings := v_consign.asking_price - v_platform_fee;

    -- 3. 锁定买家钱包
    SELECT * INTO v_buyer_wallet 
    FROM public.wallets 
    WHERE user_id = p_buyer_id
    FOR UPDATE;

    IF NOT FOUND THEN
        -- 自动创建钱包
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

    -- 6. 创建订单
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
            'purchase', v_order_id, 'order', '购买 ' || v_consign.card_name);

    -- 9. 卖家收入（该阶段直接入账）
    UPDATE public.wallets 
    SET balance = balance + v_seller_earnings,
        total_earned = total_earned + v_seller_earnings,
        updated_at = NOW()
    WHERE user_id = v_consign.seller_id;

    INSERT INTO public.wallet_transactions (wallet_id, user_id, amount, balance_after, type, reference_id, reference_type, description)
    VALUES (v_seller_wallet.id, v_consign.seller_id, v_seller_earnings, v_seller_wallet.balance + v_seller_earnings,
            'sale', v_order_id, 'order', '售出 ' || v_consign.card_name);

    -- 10. 平台手续费入库（平台虚拟账户不记钱包，只记账）
    INSERT INTO public.platform_fees (order_id, consignment_id, fee_type, fee_amount, fee_pct, currency, description)
    VALUES (v_order_id, p_consignment_id, 'transaction', v_platform_fee, v_fee_pct, 'CNY', 
            v_consign.card_name || ' 交易手续费');

    -- 11. 卖家库存：减少收藏数量
    IF v_consign.collection_id IS NOT NULL THEN
        v_seller_collection_id := v_consign.collection_id;
        
        UPDATE public.user_collections
        SET quantity = GREATEST(quantity - 1, 0),
            reserved_quantity = GREATEST(reserved_quantity - 1, 0),
            updated_at = NOW()
        WHERE id = v_seller_collection_id;
    END IF;

    -- 12. 买家库存：增加或新建收藏
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

    -- 13. 同步 card_prices（若存在同名卡牌则更新）
    INSERT INTO public.card_prices (card_name, series, rarity, card_category, current_price, previous_price, market, currency, data_source)
    VALUES (v_consign.card_name, v_consign.series, v_consign.rarity, v_consign.card_category,
            v_consign.asking_price, v_consign.asking_price, 'CN', 'CNY', 'market')
    ON CONFLICT (card_name, series, rarity, market) DO UPDATE
    SET current_price = EXCLUDED.current_price,
        updated_at = NOW();

    RETURN json_build_object(
        'success', true,
        'order_id', v_order_id,
        'order_no', v_order_no,
        'total_amount', v_total_amount,
        'platform_fee', v_platform_fee,
        'seller_earnings', v_seller_earnings,
        'card_name', v_consign.card_name
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 3: 取消寄售（释放冻结库存）
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_consignment(
    p_user_id UUID,
    p_consignment_id UUID
) RETURNS JSON AS $$
DECLARE
    v_consign RECORD;
BEGIN
    -- 锁定寄售单
    SELECT * INTO v_consign 
    FROM public.consignments 
    WHERE id = p_consignment_id AND seller_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '寄售单不存在或不属于你');
    END IF;

    IF v_consign.status != 'active' THEN
        RETURN json_build_object('success', false, 'error', '只能取消活跃状态的寄售单');
    END IF;

    -- 更新寄售状态
    UPDATE public.consignments 
    SET status = 'cancelled', updated_at = NOW()
    WHERE id = p_consignment_id;

    -- 释放冻结库存
    IF v_consign.collection_id IS NOT NULL THEN
        UPDATE public.user_collections
        SET reserved_quantity = GREATEST(reserved_quantity - 1, 0),
            updated_at = NOW()
        WHERE id = v_consign.collection_id;
    END IF;

    RETURN json_build_object(
        'success', true,
        'message', '寄售单已取消，库存已释放'
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 4: Dashboard 交易统计
-- ============================================================
CREATE OR REPLACE FUNCTION get_dashboard_trade_stats()
RETURNS JSON AS $$
DECLARE
    v_today_orders INTEGER;
    v_today_gmv NUMERIC;
    v_today_fees NUMERIC;
    v_active_listings INTEGER;
    v_total_listings INTEGER;
BEGIN
    -- 今日成交量
    SELECT COUNT(*) INTO v_today_orders FROM public.orders 
    WHERE created_at::date = CURRENT_DATE AND status IN ('paid', 'shipped', 'delivered', 'completed');

    -- 今日GMV
    SELECT COALESCE(SUM(total_amount), 0) INTO v_today_gmv FROM public.orders
    WHERE created_at::date = CURRENT_DATE AND status IN ('paid', 'shipped', 'delivered', 'completed');

    -- 今日平台佣金
    SELECT COALESCE(SUM(fee_amount), 0) INTO v_today_fees FROM public.platform_fees
    WHERE created_at::date = CURRENT_DATE;

    -- 活跃挂单数
    SELECT COUNT(*) INTO v_active_listings FROM public.consignments WHERE status = 'active';

    -- 总挂牌数
    SELECT COUNT(*) INTO v_total_listings FROM public.consignments;

    RETURN json_build_object(
        'today_orders', COALESCE(v_today_orders, 0),
        'today_gmv', COALESCE(v_today_gmv, 0),
        'today_fees', COALESCE(v_today_fees, 0),
        'active_listings', COALESCE(v_active_listings, 0),
        'total_listings', COALESCE(v_total_listings, 0)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 5: 获取用户可上架的收藏列表（排除已全部上架的）
-- ============================================================
CREATE OR REPLACE FUNCTION get_listable_collections(p_user_id UUID)
RETURNS TABLE(
    collection_id UUID,
    card_name TEXT,
    card_image TEXT,
    series TEXT,
    rarity TEXT,
    card_category TEXT,
    condition TEXT,
    total_qty INTEGER,
    available_qty INTEGER,
    current_price NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        uc.id,
        uc.card_name,
        uc.card_image,
        uc.series,
        uc.rarity,
        uc.card_category,
        uc.condition,
        uc.quantity,
        uc.quantity - COALESCE(uc.reserved_quantity, 0),
        uc.current_price
    FROM public.user_collections uc
    WHERE uc.user_id = p_user_id
      AND uc.quantity - COALESCE(uc.reserved_quantity, 0) > 0;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
