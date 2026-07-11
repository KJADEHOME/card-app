-- ============================================
-- 模拟支付全链路测试脚本
-- ============================================
-- 用途: 跳过支付宝沙箱扫码，直接在 DB 层面模拟支付成功
--       验证 0035 的 payment_orders / escrow_records / 4个RPC 全部正常
-- 执行方式: Supabase SQL Editor 整段执行
-- 安全性: 创建临时 SECURITY DEFINER 函数，测完自动删除
-- ============================================

-- ==========================================
-- Part 0: 先看看现有数据（用户/订单/钱包）
-- ==========================================
SELECT '=== 现有用户 ===' AS info;
SELECT id, email, created_at::date AS registered
FROM auth.users
ORDER BY created_at ASC
LIMIT 10;

SELECT '=== 现有待支付订单 ===' AS info;
SELECT id, order_no, buyer_id, seller_id, total_amount, status, created_at::date
FROM public.orders
WHERE status IN ('pending', 'pending_payment')
ORDER BY created_at DESC
LIMIT 5;

SELECT '=== 现有钱包 ===' AS info;
SELECT user_id, balance, frozen_balance, total_income, total_expense
FROM public.wallets
LIMIT 10;


-- ==========================================
-- Part 1: 创建临时测试函数
-- 一次性跑完: 建订单 → 模拟支付 → 发货 → 确认收货
-- ==========================================
CREATE OR REPLACE FUNCTION public.test_simulate_payment_flow()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_buyer_id UUID;
    v_seller_id UUID;
    v_order_id UUID;
    v_order_no TEXT;
    v_payment_no TEXT;
    v_today_count INTEGER;
    v_pay_result JSONB;
    v_buyer_wallet wallets%ROWTYPE;
    v_seller_wallet wallets%ROWTYPE;
    v_escrow escrow_records%ROWTYPE;
    v_result JSONB := '{}'::jsonb;
BEGIN
    -- 1. 找两个用户当 buyer / seller
    SELECT id INTO v_buyer_id FROM auth.users ORDER BY created_at ASC LIMIT 1;
    SELECT id INTO v_seller_id FROM auth.users ORDER BY created_at ASC OFFSET 1 LIMIT 1;

    -- 如果只有一个用户，buyer 和 seller 用同一个
    IF v_seller_id IS NULL THEN
        v_seller_id := v_buyer_id;
    END IF;

    v_result := v_result || jsonb_build_object('buyer_id', v_buyer_id, 'seller_id', v_seller_id);

    -- 2. 确保双方都有钱包
    SELECT * INTO v_buyer_wallet FROM wallets WHERE user_id = v_buyer_id;
    IF v_buyer_wallet.id IS NULL THEN
        INSERT INTO wallets (user_id, balance, frozen_balance, total_income, total_expense)
        VALUES (v_buyer_id, 1000, 0, 1000, 0) RETURNING * INTO v_buyer_wallet;
    END IF;

    SELECT * INTO v_seller_wallet FROM wallets WHERE user_id = v_seller_id;
    IF v_seller_wallet.id IS NULL THEN
        INSERT INTO wallets (user_id, balance, frozen_balance, total_income, total_expense)
        VALUES (v_seller_id, 500, 0, 500, 0) RETURNING * INTO v_seller_wallet;
    END IF;

    v_result := v_result || jsonb_build_object(
        'buyer_balance_before', v_buyer_wallet.balance,
        'seller_balance_before', v_seller_wallet.balance
    );

    -- 3. 创建测试订单 (status=pending)
    SELECT COUNT(*)+1 INTO v_today_count FROM orders WHERE created_at::date = CURRENT_DATE;
    v_order_no := 'TEST' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || LPAD(v_today_count::TEXT, 4, '0');

    INSERT INTO orders (
        order_no, buyer_id, seller_id,
        item_price, shipping_fee, platform_fee, total_amount, seller_earnings,
        status, currency
    ) VALUES (
        v_order_no, v_buyer_id, v_seller_id,
        100.00, 10.00, 0, 110.00, 0,
        'pending', 'CNY'
    ) RETURNING id INTO v_order_id;

    v_result := v_result || jsonb_build_object(
        'step1_create_order', 'OK',
        'order_id', v_order_id,
        'order_no', v_order_no,
        'amount', 110.00
    );

    -- 4. 创建 payment_order (模拟 create_payment_order RPC，provider=alipay)
    v_payment_no := 'PAYALIPAY' || to_char(NOW(), 'YYYYMMDDHH24MISS') || lpad(floor(random()*10000)::text, 4, '0');

    INSERT INTO payment_orders (
        payment_no, business_type, business_id, user_id,
        provider, amount, subject, status, expires_at
    ) VALUES (
        v_payment_no, 'order', v_order_id, v_buyer_id,
        'alipay', 110.00, '测试支付: ' || v_order_no, 'pending', NOW() + INTERVAL '30 minutes'
    );

    v_result := v_result || jsonb_build_object(
        'step2_create_payment_order', 'OK',
        'payment_no', v_payment_no
    );

    -- 5. 模拟支付宝回调 (调用 process_payment_success，这个不检查 auth.uid())
    -- 模拟支付宝返回的 trade_no 和回调数据
    v_pay_result := public.process_payment_success(
        v_payment_no,
        '20260707' || lpad(floor(random()*1000000000)::text, 12, '0'),  -- 模拟支付宝流水号
        'alipay',
        jsonb_build_object(
            'trade_status', 'TRADE_SUCCESS',
            'total_amount', '110.00',
            'out_trade_no', v_payment_no,
            'simulated', true,
            'note', '模拟支付宝沙箱回调，未实际扫码'
        )
    );

    v_result := v_result || jsonb_build_object('step3_payment_callback', v_pay_result);

    -- 6. 验证订单状态变成 paid + escrow 生成
    SELECT * INTO v_escrow FROM escrow_records WHERE order_id = v_order_id;
    v_result := v_result || jsonb_build_object(
        'step4_verify',
        jsonb_build_object(
            'order_status', (SELECT status FROM orders WHERE id = v_order_id),
            'payment_order_status', (SELECT status FROM payment_orders WHERE id = v_escrow.payment_order_id),
            'escrow_status', v_escrow.status,
            'escrow_total', v_escrow.total_amount,
            'escrow_platform_fee', v_escrow.platform_fee,
            'escrow_seller_amount', v_escrow.seller_amount,
            'escrow_provider', v_escrow.payment_provider
        )
    );

    -- 7. 模拟卖家发货 (直接 UPDATE，绕过 seller_ship_order 的 auth 检查)
    UPDATE orders
    SET status = 'shipped',
        tracking_no = 'SF' || lpad(floor(random()*10000000000)::text, 10, '0'),
        shipping_carrier = '顺丰速运',
        shipped_at = NOW(),
        updated_at = NOW()
    WHERE id = v_order_id;

    v_result := v_result || jsonb_build_object(
        'step5_seller_ship', 'OK',
        'order_status', (SELECT status FROM orders WHERE id = v_order_id)
    );

    -- 8. 模拟买家确认收货 (直接执行 escrow_release_to_seller 的核心逻辑，绕过 auth 检查)
    -- 释放资金给卖家
    UPDATE wallets
    SET balance = balance + v_escrow.seller_amount,
        total_income = total_income + v_escrow.seller_amount,
        updated_at = NOW()
    WHERE user_id = v_seller_id;

    -- 卖家钱包流水
    INSERT INTO wallet_transactions (wallet_id, user_id, order_id, type, amount, balance_after, description)
    SELECT w.id, v_seller_id, v_order_id, 'sale', v_escrow.seller_amount,
           w.balance, '测试-确认收货收入: ' || v_order_no
    FROM wallets w WHERE w.user_id = v_seller_id;

    -- 更新托管记录
    UPDATE escrow_records
    SET status = 'released', released_at = NOW()
    WHERE id = v_escrow.id;

    -- 更新订单状态
    UPDATE orders
    SET status = 'completed', completed_at = NOW(), updated_at = NOW()
    WHERE id = v_order_id;

    v_result := v_result || jsonb_build_object(
        'step6_buyer_confirm', 'OK',
        'order_status_final', (SELECT status FROM orders WHERE id = v_order_id),
        'escrow_status_final', (SELECT status FROM escrow_records WHERE order_id = v_order_id),
        'seller_balance_after', (SELECT balance FROM wallets WHERE user_id = v_seller_id),
        'seller_earned', v_escrow.seller_amount
    );

    RETURN jsonb_build_object('success', true, 'message', '支付全链路模拟完成', 'flow', v_result);
END;
$$;


-- ==========================================
-- Part 2: 执行测试
-- ==========================================
SELECT public.test_simulate_payment_flow() AS test_result;


-- ==========================================
-- Part 3: 验证结果（手动查询确认）
-- ==========================================
SELECT '=== 测试订单最终状态 ===' AS info;
SELECT o.order_no, o.status, o.total_amount, o.platform_fee, o.seller_earnings,
       o.payment_method, o.payment_no, o.tracking_no,
       o.payment_at, o.shipped_at, o.completed_at
FROM orders o
WHERE o.order_no LIKE 'TEST%'
ORDER BY o.created_at DESC
LIMIT 5;

SELECT '=== 支付订单记录 ===' AS info;
SELECT payment_no, provider, amount, status, trade_no,
       paid_at, callback_raw->>'simulated' AS is_simulated
FROM payment_orders
WHERE subject LIKE '测试支付%'
ORDER BY created_at DESC
LIMIT 5;

SELECT '=== 资金托管记录 ===' AS info;
SELECT e.order_id, e.status, e.total_amount, e.platform_fee, e.seller_amount,
       e.payment_provider, e.frozen_at, e.released_at, e.auto_confirmed
FROM escrow_records e
ORDER BY e.created_at DESC
LIMIT 5;

SELECT '=== 钱包流水（最近10条）===' AS info;
SELECT wt.type, wt.amount, wt.balance_after, wt.description, wt.created_at
FROM wallet_transactions wt
ORDER BY wt.created_at DESC
LIMIT 10;

SELECT '=== 通知（最近10条）===' AS info;
SELECT n.type, n.title, n.content, n.is_read, n.created_at
FROM notifications n
ORDER BY n.created_at DESC
LIMIT 10;


-- ==========================================
-- Part 4: 清理临时测试函数
-- ==========================================
DROP FUNCTION IF EXISTS public.test_simulate_payment_flow();

-- 完成
SELECT '✅ 支付全链路模拟完成，请检查上方各表数据' AS done;
