-- ============================================
-- 0035: 支付宝/微信支付接入 + 平台资金担保监管系统
-- ============================================
-- 依赖: orders, wallets, wallet_transactions 表
-- 功能:
--   1. 第三方支付订单表 (payment_orders)
--   2. 资金托管记录表 (escrow_records)
--   3. 支付成功处理 RPC (process_payment_success)
--   4. 余额支付冻结 RPC (pay_with_balance)
--   5. 资金释放 RPC (escrow_release_to_seller)
--   6. 资金退款 RPC (escrow_refund_to_buyer)
--   7. 超时自动确认 RPC (escrow_auto_confirm)
-- ============================================

-- ==========================================
-- 0. platform_config 表（如不存在则创建）
-- ==========================================
CREATE TABLE IF NOT EXISTS public.platform_config (
    key TEXT PRIMARY KEY,
    value TEXT,
    description TEXT,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 平台手续费率配置
INSERT INTO public.platform_config (key, value, description) VALUES
    ('platform_fee_rate', '0.03', '平台手续费率 (3%)'),
    ('auto_confirm_days', '7', '发货后自动确认收货天数'),
    ('auto_cancel_hours', '24', '待支付订单自动取消小时数')
ON CONFLICT (key) DO NOTHING;

-- ==========================================
-- 1. 第三方支付订单表
-- ==========================================
CREATE TABLE IF NOT EXISTS public.payment_orders (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    payment_no TEXT UNIQUE NOT NULL,              -- 支付订单号 PAY + 时间戳 + 随机数
    business_type TEXT NOT NULL DEFAULT 'order',  -- order(订单支付) / recharge(充值)
    business_id UUID,                             -- 关联的 orders.id 或 NULL(充值)
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    provider TEXT NOT NULL CHECK (provider IN ('alipay', 'wechat', 'balance')),
    amount DECIMAL(12,2) NOT NULL,                -- 支付金额（分转元后）
    subject TEXT NOT NULL,                        -- 订单标题
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid', 'failed', 'closed', 'refunded')),
    pay_url TEXT,                                 -- 支付链接（H5/PC）
    qrcode_url TEXT,                              -- 二维码链接（扫码支付）
    trade_no TEXT,                                -- 第三方交易流水号（支付宝/微信返回）
    callback_raw JSONB,                           -- 回调原始数据
    expires_at TIMESTAMP WITH TIME ZONE,          -- 过期时间
    paid_at TIMESTAMP WITH TIME ZONE,             -- 支付成功时间
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_orders_user ON public.payment_orders(user_id);
CREATE INDEX IF NOT EXISTS idx_payment_orders_business ON public.payment_orders(business_type, business_id);
CREATE INDEX IF NOT EXISTS idx_payment_orders_status ON public.payment_orders(status);
CREATE INDEX IF NOT EXISTS idx_payment_orders_no ON public.payment_orders(payment_no);
CREATE INDEX IF NOT EXISTS idx_payment_orders_trade ON public.payment_orders(trade_no);

ALTER TABLE public.payment_orders ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "payment_orders_select_own" ON public.payment_orders;
CREATE POLICY "payment_orders_select_own" ON public.payment_orders
    FOR SELECT USING (auth.uid() = user_id);
DROP POLICY IF EXISTS "payment_orders_insert_own" ON public.payment_orders;
CREATE POLICY "payment_orders_insert_own" ON public.payment_orders
    FOR INSERT WITH CHECK (auth.uid() = user_id);
DROP POLICY IF EXISTS "payment_orders_update_own" ON public.payment_orders;
CREATE POLICY "payment_orders_update_own" ON public.payment_orders
    FOR UPDATE USING (true);

-- ==========================================
-- 2. 资金托管记录表
-- ==========================================
CREATE TABLE IF NOT EXISTS public.escrow_records (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE NOT NULL UNIQUE,
    payment_order_id UUID REFERENCES public.payment_orders(id) ON DELETE SET NULL,
    buyer_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    seller_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    total_amount DECIMAL(12,2) NOT NULL,          -- 订单总额
    platform_fee DECIMAL(12,2) NOT NULL DEFAULT 0,-- 平台手续费
    seller_amount DECIMAL(12,2) NOT NULL DEFAULT 0,-- 卖家应得
    payment_provider TEXT NOT NULL,               -- alipay / wechat / balance
    status TEXT NOT NULL DEFAULT 'frozen' CHECK (status IN ('frozen', 'released', 'refunded', 'disputed')),
    frozen_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    released_at TIMESTAMP WITH TIME ZONE,
    refunded_at TIMESTAMP WITH TIME ZONE,
    auto_confirmed BOOLEAN DEFAULT false,         -- 是否超时自动确认
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_escrow_buyer ON public.escrow_records(buyer_id);
CREATE INDEX IF NOT EXISTS idx_escrow_seller ON public.escrow_records(seller_id);
CREATE INDEX IF NOT EXISTS idx_escrow_status ON public.escrow_records(status);
CREATE INDEX IF NOT EXISTS idx_escrow_order ON public.escrow_records(order_id);

ALTER TABLE public.escrow_records ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "escrow_select_parties" ON public.escrow_records;
CREATE POLICY "escrow_select_parties" ON public.escrow_records
    FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

-- 触发器: 更新 updated_at
DROP TRIGGER IF EXISTS update_payment_orders_updated_at ON public.payment_orders;
CREATE TRIGGER update_payment_orders_updated_at
    BEFORE UPDATE ON public.payment_orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_escrow_records_updated_at ON public.escrow_records;
CREATE TRIGGER update_escrow_records_updated_at
    BEFORE UPDATE ON public.escrow_records
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ==========================================
-- 3. RPC: 余额支付（冻结买家余额）
-- ==========================================
CREATE OR REPLACE FUNCTION public.pay_with_balance(
    p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_wallet public.wallets%ROWTYPE;
    v_fee_rate NUMERIC;
    v_platform_fee NUMERIC(12,2);
    v_seller_amount NUMERIC(12,2);
    v_payment_no TEXT;
BEGIN
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    IF v_order.buyer_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'error', '无权操作此订单');
    END IF;

    IF v_order.status != 'pending' AND v_order.status != 'pending_payment' THEN
        RETURN jsonb_build_object('success', false, 'error', '订单状态不允许支付: ' || v_order.status);
    END IF;

    -- 获取买家钱包（行级锁防止并发）
    SELECT * INTO v_wallet FROM public.wallets
    WHERE user_id = v_order.buyer_id FOR UPDATE;

    IF v_wallet.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '钱包不存在，请先创建钱包');
    END IF;

    IF v_wallet.balance < v_order.total_amount THEN
        RETURN jsonb_build_object('success', false, 'error', '余额不足',
            'balance', v_wallet.balance, 'need', v_order.total_amount);
    END IF;

    -- 计算手续费和卖家应得
    SELECT value::numeric INTO v_fee_rate FROM public.platform_config WHERE key = 'platform_fee_rate';
    v_fee_rate := COALESCE(v_fee_rate, 0.03);
    v_platform_fee := ROUND(v_order.total_amount * v_fee_rate, 2);
    v_seller_amount := v_order.total_amount - v_platform_fee;

    -- 生成支付单号
    v_payment_no := 'PAY' || to_char(NOW(), 'YYYYMMDDHH24MISS') || lpad(floor(random()*10000)::text, 4, '0');

    -- 扣减买家余额，增加冻结余额
    UPDATE public.wallets
    SET balance = balance - v_order.total_amount,
        frozen_balance = frozen_balance + v_order.total_amount,
        total_expense = total_expense + v_order.total_amount,
        updated_at = NOW()
    WHERE id = v_wallet.id;

    -- 更新订单状态
    UPDATE public.orders
    SET status = 'paid',
        payment_method = 'balance',
        payment_at = NOW(),
        payment_no = v_payment_no,
        platform_fee = v_platform_fee,
        seller_amount = v_seller_amount,
        updated_at = NOW()
    WHERE id = p_order_id;

    -- 创建支付订单记录
    INSERT INTO public.payment_orders (payment_no, business_type, business_id, user_id, provider, amount, subject, status, paid_at)
    VALUES (v_payment_no, 'order', p_order_id, v_order.buyer_id, 'balance', v_order.total_amount,
            '余额支付: ' || v_order.order_no, 'paid', NOW());

    -- 创建托管记录
    INSERT INTO public.escrow_records (order_id, buyer_id, seller_id, total_amount, platform_fee, seller_amount, payment_provider, status, frozen_at)
    VALUES (p_order_id, v_order.buyer_id, v_order.seller_id, v_order.total_amount, v_platform_fee, v_seller_amount, 'balance', 'frozen', NOW());

    -- 记录买家钱包流水
    INSERT INTO public.wallet_transactions (wallet_id, user_id, order_id, type, amount, balance_after, description)
    VALUES (v_wallet.id, v_order.buyer_id, p_order_id, 'payment', v_order.total_amount,
            v_wallet.balance - v_order.total_amount, '余额支付订单: ' || v_order.order_no);

    -- 通知卖家
    INSERT INTO public.notifications (user_id, type, title, content, related_id)
    VALUES (v_order.seller_id, 'order_paid', '买家已付款',
            '订单 ' || v_order.order_no || ' 买家已付款，资金已托管，请尽快发货', p_order_id);

    RETURN jsonb_build_object('success', true, 'message', '支付成功，资金已托管',
        'payment_no', v_payment_no, 'balance_after', v_wallet.balance - v_order.total_amount);
END;
$$;

COMMENT ON FUNCTION public.pay_with_balance(UUID) IS '余额支付订单，冻结资金到平台托管';

-- ==========================================
-- 4. RPC: 第三方支付成功处理（回调触发）
-- ==========================================
CREATE OR REPLACE FUNCTION public.process_payment_success(
    p_payment_no TEXT,
    p_trade_no TEXT,
    p_provider TEXT,
    p_callback_raw JSONB
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_pay_order public.payment_orders%ROWTYPE;
    v_order public.orders%ROWTYPE;
    v_fee_rate NUMERIC;
    v_platform_fee NUMERIC(12,2);
    v_seller_amount NUMERIC(12,2);
    v_wallet public.wallets%ROWTYPE;
BEGIN
    -- 查找支付订单（行级锁防重复处理）
    SELECT * INTO v_pay_order FROM public.payment_orders
    WHERE payment_no = p_payment_no FOR UPDATE;

    IF v_pay_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '支付订单不存在: ' || p_payment_no);
    END IF;

    -- 幂等检查：已支付直接返回成功
    IF v_pay_order.status = 'paid' THEN
        RETURN jsonb_build_object('success', true, 'message', '已处理，跳过重复回调');
    END IF;

    IF v_pay_order.status != 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', '支付订单状态异常: ' || v_pay_order.status);
    END IF;

    -- 更新支付订单
    UPDATE public.payment_orders
    SET status = 'paid', trade_no = p_trade_no, callback_raw = p_callback_raw, paid_at = NOW()
    WHERE id = v_pay_order.id;

    -- 充值业务：直接加余额
    IF v_pay_order.business_type = 'recharge' THEN
        SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_pay_order.user_id;
        IF v_wallet.id IS NULL THEN
            INSERT INTO public.wallets (user_id, balance, total_income)
            VALUES (v_pay_order.user_id, v_pay_order.amount, v_pay_order.amount);
        ELSE
            UPDATE public.wallets
            SET balance = balance + v_pay_order.amount,
                total_income = total_income + v_pay_order.amount,
                updated_at = NOW()
            WHERE id = v_wallet.id;
        END IF;

        INSERT INTO public.wallet_transactions (wallet_id, user_id, type, amount, balance_after, description)
        SELECT w.id, v_pay_order.user_id, 'recharge', v_pay_order.amount,
               w.balance, p_provider || '充值 ' || v_pay_order.amount || '元'
        FROM public.wallets w WHERE w.user_id = v_pay_order.user_id;

        INSERT INTO public.notifications (user_id, type, title, content)
        VALUES (v_pay_order.user_id, 'recharge_success', '充值成功',
                p_provider || '充值 ' || v_pay_order.amount || ' 元已到账');

        RETURN jsonb_build_object('success', true, 'message', '充值成功', 'type', 'recharge');
    END IF;

    -- 订单支付业务：进入资金托管
    IF v_pay_order.business_type = 'order' THEN
        SELECT * INTO v_order FROM public.orders WHERE id = v_pay_order.business_id;
        IF v_order.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', '关联订单不存在');
        END IF;

        -- 幂等：订单已支付则跳过
        IF v_order.status IN ('paid', 'shipped', 'delivered', 'completed') THEN
            RETURN jsonb_build_object('success', true, 'message', '订单已支付，跳过');
        END IF;

        SELECT value::numeric INTO v_fee_rate FROM public.platform_config WHERE key = 'platform_fee_rate';
        v_fee_rate := COALESCE(v_fee_rate, 0.03);
        v_platform_fee := ROUND(v_order.total_amount * v_fee_rate, 2);
        v_seller_amount := v_order.total_amount - v_platform_fee;

        -- 更新订单
        UPDATE public.orders
        SET status = 'paid',
            payment_method = p_provider,
            payment_at = NOW(),
            payment_no = p_payment_no,
            platform_fee = v_platform_fee,
            seller_amount = v_seller_amount,
            updated_at = NOW()
        WHERE id = v_order.id;

        -- 创建托管记录（第三方支付钱在平台商户号，DB 层面记录托管状态）
        INSERT INTO public.escrow_records (order_id, payment_order_id, buyer_id, seller_id,
            total_amount, platform_fee, seller_amount, payment_provider, status, frozen_at)
        VALUES (v_order.id, v_pay_order.id, v_order.buyer_id, v_order.seller_id,
            v_order.total_amount, v_platform_fee, v_seller_amount, p_provider, 'frozen', NOW())
        ON CONFLICT (order_id) DO NOTHING;

        -- 通知卖家
        INSERT INTO public.notifications (user_id, type, title, content, related_id)
        VALUES (v_order.seller_id, 'order_paid', '买家已付款',
                '订单 ' || v_order.order_no || ' 买家已通过' || p_provider || '付款，资金已托管，请尽快发货', v_order.id);

        RETURN jsonb_build_object('success', true, 'message', '订单支付成功', 'type', 'order',
            'order_id', v_order.id);
    END IF;

    RETURN jsonb_build_object('success', false, 'error', '未知业务类型: ' || v_pay_order.business_type);
END;
$$;

COMMENT ON FUNCTION public.process_payment_success(TEXT, TEXT, TEXT, JSONB) IS '处理第三方支付成功回调（支付宝/微信）';

-- ==========================================
-- 5. RPC: 确认收货，释放资金给卖家
-- ==========================================
CREATE OR REPLACE FUNCTION public.escrow_release_to_seller(
    p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_escrow public.escrow_records%ROWTYPE;
    v_seller_wallet public.wallets%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    IF v_order.buyer_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'error', '仅买家可确认收货');
    END IF;

    IF v_order.status NOT IN ('shipped', 'delivered') THEN
        RETURN jsonb_build_object('success', false, 'error', '订单状态不允许确认收货: ' || v_order.status);
    END IF;

    SELECT * INTO v_escrow FROM public.escrow_records WHERE order_id = p_order_id FOR UPDATE;
    IF v_escrow.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '托管记录不存在');
    END IF;

    IF v_escrow.status != 'frozen' THEN
        RETURN jsonb_build_object('success', false, 'error', '资金已处理，当前状态: ' || v_escrow.status);
    END IF;

    -- 释放资金：如果是余额支付，从 frozen_balance 释放；第三方支付则直接计入卖家余额
    IF v_escrow.payment_provider = 'balance' THEN
        -- 买家冻结余额减少
        UPDATE public.wallets
        SET frozen_balance = frozen_balance - v_escrow.total_amount,
            updated_at = NOW()
        WHERE user_id = v_escrow.buyer_id;
    END IF;

    -- 卖家余额增加（扣除手续费后的应得金额）
    SELECT * INTO v_seller_wallet FROM public.wallets WHERE user_id = v_escrow.seller_id;
    IF v_seller_wallet.id IS NULL THEN
        INSERT INTO public.wallets (user_id, balance, total_income)
        VALUES (v_escrow.seller_id, v_escrow.seller_amount, v_escrow.seller_amount);
    ELSE
        UPDATE public.wallets
        SET balance = balance + v_escrow.seller_amount,
            total_income = total_income + v_escrow.seller_amount,
            updated_at = NOW()
        WHERE user_id = v_escrow.seller_id;
    END IF;

    -- 卖家钱包流水
    INSERT INTO public.wallet_transactions (wallet_id, user_id, order_id, type, amount, balance_after, description)
    SELECT w.id, v_escrow.seller_id, p_order_id, 'sale', v_escrow.seller_amount,
           w.balance, '订单完成收入: ' || v_order.order_no
    FROM public.wallets w WHERE w.user_id = v_escrow.seller_id;

    -- 更新托管记录
    UPDATE public.escrow_records
    SET status = 'released', released_at = NOW()
    WHERE id = v_escrow.id;

    -- 更新订单状态
    UPDATE public.orders
    SET status = 'completed', completed_at = NOW(), updated_at = NOW()
    WHERE id = p_order_id;

    -- 通知卖家
    INSERT INTO public.notifications (user_id, type, title, content, related_id)
    VALUES (v_escrow.seller_id, 'order_completed', '订单已完成',
            '买家已确认收货，订单 ' || v_order.order_no || ' 已完成，' || v_escrow.seller_amount || ' 元已到账', p_order_id);

    RETURN jsonb_build_object('success', true, 'message', '确认收货成功，资金已释放给卖家',
        'seller_amount', v_escrow.seller_amount);
END;
$$;

COMMENT ON FUNCTION public.escrow_release_to_seller(UUID) IS '买家确认收货，释放托管资金给卖家';

-- ==========================================
-- 6. RPC: 退款，资金退回买家
-- ==========================================
CREATE OR REPLACE FUNCTION public.escrow_refund_to_buyer(
    p_order_id UUID,
    p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_escrow public.escrow_records%ROWTYPE;
    v_buyer_wallet public.wallets%ROWTYPE;
BEGIN
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    -- 买家或卖家或管理员均可触发（管理员通过 service_role 调用）
    IF auth.uid() IS NOT NULL AND auth.uid() != v_order.buyer_id AND auth.uid() != v_order.seller_id THEN
        RETURN jsonb_build_object('success', false, 'error', '无权操作');
    END IF;

    SELECT * INTO v_escrow FROM public.escrow_records WHERE order_id = p_order_id FOR UPDATE;
    IF v_escrow.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '托管记录不存在');
    END IF;

    IF v_escrow.status != 'frozen' THEN
        RETURN jsonb_build_object('success', false, 'error', '资金已处理，当前状态: ' || v_escrow.status);
    END IF;

    -- 退款给买家
    IF v_escrow.payment_provider = 'balance' THEN
        -- 余额支付：冻结余额退回可用余额
        UPDATE public.wallets
        SET frozen_balance = frozen_balance - v_escrow.total_amount,
            balance = balance + v_escrow.total_amount,
            updated_at = NOW()
        WHERE user_id = v_escrow.buyer_id;
    ELSE
        -- 第三方支付：退款记入买家钱包余额（实际退款由支付服务端调第三方退款API）
        SELECT * INTO v_buyer_wallet FROM public.wallets WHERE user_id = v_escrow.buyer_id;
        IF v_buyer_wallet.id IS NULL THEN
            INSERT INTO public.wallets (user_id, balance, total_income)
            VALUES (v_escrow.buyer_id, v_escrow.total_amount, v_escrow.total_amount);
        ELSE
            UPDATE public.wallets
            SET balance = balance + v_escrow.total_amount,
                total_income = total_income + v_escrow.total_amount,
                updated_at = NOW()
            WHERE user_id = v_escrow.buyer_id;
        END IF;
    END IF;

    -- 买家钱包流水
    INSERT INTO public.wallet_transactions (wallet_id, user_id, order_id, type, amount, balance_after, description)
    SELECT w.id, v_escrow.buyer_id, p_order_id, 'refund', v_escrow.total_amount,
           w.balance, '订单退款: ' || v_order.order_no
    FROM public.wallets w WHERE w.user_id = v_escrow.buyer_id;

    -- 更新托管记录
    UPDATE public.escrow_records
    SET status = 'refunded', refunded_at = NOW()
    WHERE id = v_escrow.id;

    -- 更新支付订单
    UPDATE public.payment_orders
    SET status = 'refunded'
    WHERE id = v_escrow.payment_order_id;

    -- 更新订单状态
    UPDATE public.orders
    SET status = 'refunded', updated_at = NOW()
    WHERE id = p_order_id;

    -- 通知双方
    INSERT INTO public.notifications (user_id, type, title, content, related_id)
    VALUES (v_escrow.buyer_id, 'refund_success', '退款成功',
            '订单 ' || v_order.order_no || ' 退款 ' || v_escrow.total_amount || ' 元已到账', p_order_id);
    INSERT INTO public.notifications (user_id, type, title, content, related_id)
    VALUES (v_escrow.seller_id, 'order_refunded', '订单已退款',
            '订单 ' || v_order.order_no || ' 已退款给买家', p_order_id);

    RETURN jsonb_build_object('success', true, 'message', '退款成功，资金已退回买家',
        'refund_amount', v_escrow.total_amount);
END;
$$;

COMMENT ON FUNCTION public.escrow_refund_to_buyer(UUID, TEXT) IS '退款，将托管资金退回买家';

-- ==========================================
-- 7. RPC: 超时自动确认收货（定时任务调用，service_role）
-- ==========================================
CREATE OR REPLACE FUNCTION public.escrow_auto_confirm()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_days INTEGER;
    v_count INTEGER := 0;
    v_record RECORD;
BEGIN
    SELECT value::integer INTO v_days FROM public.platform_config WHERE key = 'auto_confirm_days';
    v_days := COALESCE(v_days, 7);

    FOR v_record IN
        SELECT e.*, o.order_no, o.shipped_at
        FROM public.escrow_records e
        JOIN public.orders o ON o.id = e.order_id
        WHERE e.status = 'frozen'
          AND o.status = 'shipped'
          AND o.shipped_at IS NOT NULL
          AND o.shipped_at < NOW() - (v_days || ' days')::INTERVAL
    LOOP
        -- 释放资金给卖家
        UPDATE public.wallets
        SET frozen_balance = GREATEST(frozen_balance - v_record.total_amount, 0),
            updated_at = NOW()
        WHERE user_id = v_record.buyer_id AND v_record.payment_provider = 'balance';

        UPDATE public.wallets
        SET balance = balance + v_record.seller_amount,
            total_income = total_income + v_record.seller_amount,
            updated_at = NOW()
        WHERE user_id = v_record.seller_id;

        INSERT INTO public.wallet_transactions (wallet_id, user_id, order_id, type, amount, balance_after, description)
        SELECT w.id, v_record.seller_id, v_record.order_id, 'sale', v_record.seller_amount,
               w.balance, '超时自动确认收入: ' || v_record.order_no
        FROM public.wallets w WHERE w.user_id = v_record.seller_id;

        UPDATE public.escrow_records
        SET status = 'released', released_at = NOW(), auto_confirmed = true
        WHERE id = v_record.id;

        UPDATE public.orders
        SET status = 'completed', completed_at = NOW(), updated_at = NOW()
        WHERE id = v_record.order_id;

        INSERT INTO public.notifications (user_id, type, title, content, related_id)
        VALUES (v_record.buyer_id, 'auto_confirmed', '订单已自动确认',
                '订单 ' || v_record.order_no || ' 已超过' || v_days || '天，系统自动确认收货', v_record.order_id);
        INSERT INTO public.notifications (user_id, type, title, content, related_id)
        VALUES (v_record.seller_id, 'order_completed', '订单已完成',
                '订单 ' || v_record.order_no || ' 自动确认完成，' || v_record.seller_amount || ' 元已到账', v_record.order_id);

        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'auto_confirmed_count', v_count);
END;
$$;

COMMENT ON FUNCTION public.escrow_auto_confirm() IS '超时自动确认收货（定时任务调用）';

-- ==========================================
-- 8. RPC: 创建支付订单（前端调用，生成预支付记录）
-- ==========================================
CREATE OR REPLACE FUNCTION public.create_payment_order(
    p_business_type TEXT,
    p_business_id UUID,
    p_provider TEXT,
    p_amount DECIMAL(12,2),
    p_subject TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_payment_no TEXT;
    v_order public.orders%ROWTYPE;
    v_actual_amount DECIMAL(12,2);
    v_actual_subject TEXT;
BEGIN
    IF p_provider NOT IN ('alipay', 'wechat') THEN
        RETURN jsonb_build_object('success', false, 'error', '不支持的支付方式: ' || p_provider);
    END IF;

    IF p_business_type = 'order' THEN
        SELECT * INTO v_order FROM public.orders WHERE id = p_business_id;
        IF v_order.id IS NULL THEN
            RETURN jsonb_build_object('success', false, 'error', '订单不存在');
        END IF;
        IF v_order.buyer_id != auth.uid() THEN
            RETURN jsonb_build_object('success', false, 'error', '无权操作');
        END IF;
        IF v_order.status NOT IN ('pending', 'pending_payment') THEN
            RETURN jsonb_build_object('success', false, 'error', '订单已支付或已取消');
        END IF;
        v_actual_amount := v_order.total_amount;
        v_actual_subject := '卡域订单: ' || v_order.order_no;
    ELSIF p_business_type = 'recharge' THEN
        v_actual_amount := p_amount;
        v_actual_subject := COALESCE(p_subject, '卡域钱包充值');
    ELSE
        RETURN jsonb_build_object('success', false, 'error', '未知业务类型');
    END IF;

    v_payment_no := 'PAY' || UPPER(p_provider) || to_char(NOW(), 'YYYYMMDDHH24MISS') || lpad(floor(random()*10000)::text, 4, '0');

    INSERT INTO public.payment_orders (payment_no, business_type, business_id, user_id, provider, amount, subject, status, expires_at)
    VALUES (v_payment_no, p_business_type, p_business_id, auth.uid(), p_provider, v_actual_amount, v_actual_subject, 'pending', NOW() + INTERVAL '30 minutes');

    RETURN jsonb_build_object('success', true,
        'payment_no', v_payment_no,
        'amount', v_actual_amount,
        'subject', v_actual_subject,
        'provider', p_provider,
        'business_type', p_business_type);
END;
$$;

COMMENT ON FUNCTION public.create_payment_order(TEXT, UUID, TEXT, DECIMAL, TEXT) IS '创建第三方支付订单（预支付）';
