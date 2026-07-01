-- ============================================
-- 0018: 订单状态机完善 — 发货/收货/退款/争议
-- ============================================
-- 依赖: 0006 (orders表)

-- ============================================
-- 1. 卖家发货 RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.seller_ship_order(
    p_order_id UUID,
    p_tracking_no TEXT,
    p_shipping_carrier TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
BEGIN
    -- 获取订单
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    -- 权限检查：只有卖家可以发货
    IF v_order.seller_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'error', '无权操作');
    END IF;

    -- 状态检查：只有 paid 状态可以发货
    IF v_order.status != 'paid' THEN
        RETURN jsonb_build_object('success', false, 'error', '订单状态不允许发货，当前状态: ' || v_order.status);
    END IF;

    -- 更新订单
    UPDATE public.orders
    SET status = 'shipped',
        tracking_no = p_tracking_no,
        shipping_carrier = p_shipping_carrier,
        shipped_at = NOW(),
        updated_at = NOW()
    WHERE id = p_order_id;

    -- 创建通知给买家
    INSERT INTO public.notifications (user_id, type, title, content, related_id)
    VALUES (
        v_order.buyer_id,
        'order_shipped',
        '订单已发货',
        '您的订单 ' || v_order.order_no || ' 已发货，快递单号: ' || p_tracking_no,
        p_order_id
    );

    RETURN jsonb_build_object(
        'success', true,
        'message', '发货成功',
        'tracking_no', p_tracking_no
    );
END;
$$;

COMMENT ON FUNCTION public.seller_ship_order(UUID, TEXT, TEXT) IS '卖家发货';

-- ============================================
-- 2. 买家确认收货 RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.buyer_confirm_receipt(
    p_order_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_seller_earnings NUMERIC(12,2);
BEGIN
    -- 获取订单
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    -- 权限检查：只有买家可以确认收货
    IF v_order.buyer_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'error', '无权操作');
    END IF;

    -- 状态检查：只有 shipped 或 delivered 状态可以确认收货
    IF v_order.status NOT IN ('shipped', 'delivered') THEN
        RETURN jsonb_build_object('success', false, 'error', '订单状态不允许确认收货，当前状态: ' || v_order.status);
    END IF;

    -- 计算卖家应得（扣除平台手续费）
    v_seller_earnings := v_order.total_amount - v_order.platform_fee;

    -- 更新订单
    UPDATE public.orders
    SET status = 'completed',
        delivered_at = NOW(),
        completed_at = NOW(),
        updated_at = NOW()
    WHERE id = p_order_id;

    -- 释放资金给卖家（更新卖家钱包）
    UPDATE public.wallets
    SET balance = balance + v_seller_earnings,
        updated_at = NOW()
    WHERE user_id = v_order.seller_id;

    -- 记录钱包交易
    INSERT INTO public.wallet_transactions (user_id, type, amount, balance_after, related_id, description)
    VALUES (
        v_order.seller_id,
        'sale',
        v_seller_earnings,
        (SELECT balance FROM public.wallets WHERE user_id = v_order.seller_id),
        p_order_id,
        '订单完成: ' || v_order.order_no
    );

    -- 更新 consignment 状态为 sold
    IF v_order.consignment_id IS NOT NULL THEN
        UPDATE public.consignments
        SET status = 'sold',
            sold_at = NOW()
        WHERE id = v_order.consignment_id;
    END IF;

    -- 创建通知给卖家
    INSERT INTO public.notifications (user_id, type, title, content, related_id)
    VALUES (
        v_order.seller_id,
        'order_completed',
        '订单已完成',
        '买家已确认收货，订单 ' || v_order.order_no || ' 已完成，款项已到账',
        p_order_id
    );

    RETURN jsonb_build_object(
        'success', true,
        'message', '确认收货成功',
        'seller_earnings', v_seller_earnings
    );
END;
$$;

COMMENT ON FUNCTION public.buyer_confirm_receipt(UUID) IS '买家确认收货';

-- ============================================
-- 3. 买家申请退款 RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.buyer_request_refund(
    p_order_id UUID,
    p_reason TEXT,
    p_refund_amount NUMERIC(12,2) DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_refund_amount NUMERIC(12,2);
BEGIN
    -- 获取订单
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    -- 权限检查：只有买家可以申请退款
    IF v_order.buyer_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'error', '无权操作');
    END IF;

    -- 状态检查：paid/shipped/delivered 可以申请退款
    IF v_order.status NOT IN ('paid', 'shipped', 'delivered') THEN
        RETURN jsonb_build_object('success', false, 'error', '订单状态不允许申请退款，当前状态: ' || v_order.status);
    END IF;

    -- 计算退款金额
    v_refund_amount := COALESCE(p_refund_amount, v_order.total_amount);

    -- 更新订单状态
    UPDATE public.orders
    SET status = 'refund_requested',
        updated_at = NOW()
    WHERE id = p_order_id;

    -- 创建退款记录
    INSERT INTO public.refunds (order_id, user_id, reason, refund_amount, status, created_at)
    VALUES (p_order_id, auth.uid(), p_reason, v_refund_amount, 'pending', NOW());

    -- 创建通知给卖家
    INSERT INTO public.notifications (user_id, type, title, content, related_id)
    VALUES (
        v_order.seller_id,
        'refund_requested',
        '退款申请',
        '买家申请退款，订单 ' || v_order.order_no || '，原因: ' || p_reason,
        p_order_id
    );

    RETURN jsonb_build_object(
        'success', true,
        'message', '退款申请已提交',
        'refund_amount', v_refund_amount
    );
END;
$$;

COMMENT ON FUNCTION public.buyer_request_refund(UUID, TEXT, NUMERIC) IS '买家申请退款';

-- ============================================
-- 4. 卖家处理退款 RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.seller_process_refund(
    p_order_id UUID,
    p_approved BOOLEAN,
    p_seller_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
    v_refund public.refunds%ROWTYPE;
BEGIN
    -- 获取订单
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    -- 权限检查：只有卖家可以处理退款
    IF v_order.seller_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'error', '无权操作');
    END IF;

    -- 状态检查
    IF v_order.status != 'refund_requested' THEN
        RETURN jsonb_build_object('success', false, 'error', '订单状态不是退款申请状态');
    END IF;

    -- 获取退款记录
    SELECT * INTO v_refund FROM public.refunds WHERE order_id = p_order_id AND status = 'pending';

    IF p_approved THEN
        -- 同意退款：退款给买家
        UPDATE public.orders
        SET status = 'refunded',
            updated_at = NOW()
        WHERE id = p_order_id;

        UPDATE public.refunds
        SET status = 'approved',
            seller_note = p_seller_note,
            processed_at = NOW()
        WHERE id = v_refund.id;

        -- 退款到买家钱包
        UPDATE public.wallets
        SET balance = balance + v_refund.refund_amount,
            updated_at = NOW()
        WHERE user_id = v_order.buyer_id;

        -- 记录钱包交易
        INSERT INTO public.wallet_transactions (user_id, type, amount, balance_after, related_id, description)
        VALUES (
            v_order.buyer_id,
            'refund',
            v_refund.refund_amount,
            (SELECT balance FROM public.wallets WHERE user_id = v_order.buyer_id),
            p_order_id,
            '退款: ' || v_order.order_no
        );

        -- 通知买家
        INSERT INTO public.notifications (user_id, type, title, content, related_id)
        VALUES (
            v_order.buyer_id,
            'refund_approved',
            '退款已批准',
            '您的退款申请已批准，退款金额 ' || v_refund.refund_amount || ' 已到账',
            p_order_id
        );

        RETURN jsonb_build_object('success', true, 'message', '已同意退款');
    ELSE
        -- 拒绝退款
        UPDATE public.orders
        SET status = 'shipped',  -- 回到发货状态
            updated_at = NOW()
        WHERE id = p_order_id;

        UPDATE public.refunds
        SET status = 'rejected',
            seller_note = p_seller_note,
            processed_at = NOW()
        WHERE id = v_refund.id;

        -- 通知买家
        INSERT INTO public.notifications (user_id, type, title, content, related_id)
        VALUES (
            v_order.buyer_id,
            'refund_rejected',
            '退款已拒绝',
            '您的退款申请已被拒绝，原因: ' || COALESCE(p_seller_note, '卖家未说明原因'),
            p_order_id
        );

        RETURN jsonb_build_object('success', true, 'message', '已拒绝退款');
    END IF;
END;
$$;

COMMENT ON FUNCTION public.seller_process_refund(UUID, BOOLEAN, TEXT) IS '卖家处理退款';

-- ============================================
-- 5. 买家/卖家发起争议 RPC
-- ============================================
CREATE OR REPLACE FUNCTION public.create_order_dispute(
    p_order_id UUID,
    p_reason TEXT,
    p_evidence TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_order public.orders%ROWTYPE;
BEGIN
    -- 获取订单
    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF v_order.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    -- 权限检查：买家或卖家可以发起争议
    IF auth.uid() != v_order.buyer_id AND auth.uid() != v_order.seller_id THEN
        RETURN jsonb_build_object('success', false, 'error', '无权操作');
    END IF;

    -- 状态检查：completed/refunded/shipped/delivered 可以发起争议
    IF v_order.status NOT IN ('completed', 'refunded', 'shipped', 'delivered', 'refund_requested') THEN
        RETURN jsonb_build_object('success', false, 'error', '订单状态不允许发起争议');
    END IF;

    -- 更新订单状态
    UPDATE public.orders
    SET status = 'disputed',
        updated_at = NOW()
    WHERE id = p_order_id;

    -- 创建争议记录
    INSERT INTO public.disputes (order_id, initiator_id, reason, evidence, status, created_at)
    VALUES (p_order_id, auth.uid(), p_reason, p_evidence, 'open', NOW());

    -- 通知对方
    DECLARE
        v_other_user UUID;
    BEGIN
        v_other_user := CASE 
            WHEN auth.uid() = v_order.buyer_id THEN v_order.seller_id 
            ELSE v_order.buyer_id 
        END;
        
        INSERT INTO public.notifications (user_id, type, title, content, related_id)
        VALUES (
            v_other_user,
            'dispute_opened',
            '争议已开启',
            '订单 ' || v_order.order_no || ' 产生争议，原因: ' || p_reason,
            p_order_id
        );
    END;

    RETURN jsonb_build_object('success', true, 'message', '争议已开启');
END;
$$;

COMMENT ON FUNCTION public.create_order_dispute(UUID, TEXT, TEXT) IS '发起订单争议';

-- ============================================
-- 6. 更新订单状态约束（增加 refund_requested）
-- ============================================
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_status_check;
ALTER TABLE public.orders ADD CONSTRAINT orders_status_check 
    CHECK (status IN ('pending','paid','shipped','delivered','completed','cancelled','refund_requested','refunded','disputed'));

-- ============================================
-- 7. 创建退款表（如果不存在）
-- ============================================
CREATE TABLE IF NOT EXISTS public.refunds (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL NOT NULL,
    reason TEXT NOT NULL,
    refund_amount NUMERIC(12,2) NOT NULL,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','completed')),
    seller_note TEXT,
    processed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_refunds_order ON public.refunds(order_id);
CREATE INDEX IF NOT EXISTS idx_refunds_user ON public.refunds(user_id);

ALTER TABLE public.refunds ENABLE ROW LEVEL SECURITY;
CREATE POLICY "refunds_select_own" ON public.refunds FOR SELECT USING (auth.uid() = user_id OR auth.uid() IN (SELECT seller_id FROM public.orders WHERE id = order_id));
CREATE POLICY "refunds_insert_own" ON public.refunds FOR INSERT WITH CHECK (auth.uid() = user_id);

COMMENT ON TABLE public.refunds IS '退款记录表';

-- ============================================
-- 8. 创建争议表（如果不存在）
-- ============================================
CREATE TABLE IF NOT EXISTS public.disputes (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE NOT NULL,
    initiator_id UUID REFERENCES auth.users(id) ON DELETE SET NULL NOT NULL,
    reason TEXT NOT NULL,
    evidence TEXT,
    status TEXT DEFAULT 'open' CHECK (status IN ('open','closed','resolved')),
    resolver_note TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    closed_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_disputes_order ON public.disputes(order_id);
CREATE INDEX IF NOT EXISTS idx_disputes_status ON public.disputes(status);

ALTER TABLE public.disputes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "disputes_select_own" ON public.disputes FOR SELECT USING (auth.uid() = initiator_id OR auth.uid() IN (SELECT buyer_id FROM public.orders WHERE id = order_id) OR auth.uid() IN (SELECT seller_id FROM public.orders WHERE id = order_id));
CREATE POLICY "disputes_insert_own" ON public.disputes FOR INSERT WITH CHECK (auth.uid() = initiator_id);

COMMENT ON TABLE public.disputes IS '订单争议表';

-- ============================================
-- 9. 创建通知表（如果不存在）
-- ============================================
CREATE TABLE IF NOT EXISTS public.notifications (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    content TEXT,
    related_id UUID,
    is_read BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id, is_read);
CREATE INDEX IF NOT EXISTS idx_notifications_created ON public.notifications(created_at DESC);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "notifications_select_own" ON public.notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "notifications_update_own" ON public.notifications FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "notifications_insert_all" ON public.notifications FOR INSERT WITH CHECK (true);

COMMENT ON TABLE public.notifications IS '用户通知表';
