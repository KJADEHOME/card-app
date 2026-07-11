-- ============================================
-- 清理 test_simulate_payment_flow.sql 产生的测试数据（v2 修复字段名）
-- ============================================
-- 修复：notifications 表用 reference_id 或 related_id（不是 order_id）
-- 删除顺序：notifications → wallet_transactions → escrow_records → payment_orders → orders
-- 测试订单号：TEST202607070001
-- 幂等：可重复执行
-- ============================================

DO $$
DECLARE
    v_order_id UUID;
    v_payment_no TEXT;
    v_has_related_id BOOLEAN;
    v_has_reference_id BOOLEAN;
    v_has_order_id BOOLEAN;
    v_count INTEGER;
    v_tmp INTEGER;
    v_col_type TEXT;
BEGIN
    SELECT id INTO v_order_id FROM public.orders WHERE order_no = 'TEST202607070001';
    SELECT payment_no INTO v_payment_no FROM public.orders WHERE order_no = 'TEST202607070001';

    IF v_order_id IS NULL THEN
        RAISE NOTICE '⚠️ 测试订单 TEST202607070001 不存在，可能已清理过';
        RETURN;
    END IF;

    RAISE NOTICE '找到测试订单 id=%, payment_no=%', v_order_id, COALESCE(v_payment_no, 'NULL');

    -- 1. 通知（动态判断字段名）
    SELECT EXISTS(SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='notifications' AND column_name='related_id')
        INTO v_has_related_id;
    SELECT EXISTS(SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='notifications' AND column_name='reference_id')
        INTO v_has_reference_id;
    SELECT EXISTS(SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='notifications' AND column_name='order_id')
        INTO v_has_order_id;

    IF v_has_order_id THEN
        EXECUTE 'DELETE FROM public.notifications WHERE order_id = $1' USING v_order_id;
    ELSIF v_has_related_id THEN
        EXECUTE 'DELETE FROM public.notifications WHERE related_id = $1' USING v_order_id;
    ELSIF v_has_reference_id THEN
        EXECUTE 'DELETE FROM public.notifications WHERE reference_id = $1' USING v_order_id;
    END IF;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE '已删 notifications: % 行', v_count;

    -- 2. 钱包流水（兼容 order_id / reference_id / related_id 三种字段名）
    SELECT EXISTS(SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='wallet_transactions' AND column_name='order_id')
        INTO v_has_order_id;
    SELECT EXISTS(SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='wallet_transactions' AND column_name='related_id')
        INTO v_has_related_id;
    SELECT EXISTS(SELECT 1 FROM information_schema.columns
                  WHERE table_schema='public' AND table_name='wallet_transactions' AND column_name='reference_id')
        INTO v_has_reference_id;

    v_count := 0;
    IF v_has_order_id THEN
        EXECUTE 'DELETE FROM public.wallet_transactions WHERE order_id = $1' USING v_order_id;
        GET DIAGNOSTICS v_tmp = ROW_COUNT;
        v_count := v_count + v_tmp;
    END IF;
    IF v_has_related_id THEN
        SELECT data_type INTO v_col_type FROM information_schema.columns
            WHERE table_schema='public' AND table_name='wallet_transactions' AND column_name='related_id';
        IF v_col_type = 'text' THEN
            EXECUTE 'DELETE FROM public.wallet_transactions WHERE related_id = $1' USING v_order_id::TEXT;
        ELSE
            EXECUTE 'DELETE FROM public.wallet_transactions WHERE related_id = $1' USING v_order_id;
        END IF;
        GET DIAGNOSTICS v_tmp = ROW_COUNT;
        v_count := v_count + v_tmp;
    END IF;
    IF v_has_reference_id THEN
        SELECT data_type INTO v_col_type FROM information_schema.columns
            WHERE table_schema='public' AND table_name='wallet_transactions' AND column_name='reference_id';
        IF v_col_type = 'text' THEN
            EXECUTE 'DELETE FROM public.wallet_transactions WHERE reference_id = $1' USING v_order_id::TEXT;
        ELSE
            EXECUTE 'DELETE FROM public.wallet_transactions WHERE reference_id = $1' USING v_order_id;
        END IF;
        GET DIAGNOSTICS v_tmp = ROW_COUNT;
        v_count := v_count + v_tmp;
    END IF;
    RAISE NOTICE '已删 wallet_transactions: % 行', v_count;

    -- 3. 资金托管记录
    DELETE FROM public.escrow_records WHERE order_id = v_order_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE '已删 escrow_records: % 行', v_count;

    -- 4. 支付订单（payment_orders 用 business_id 关联，不是 order_id）
    DELETE FROM public.payment_orders WHERE business_id = v_order_id AND business_type = 'order';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    IF v_payment_no IS NOT NULL THEN
        DELETE FROM public.payment_orders WHERE payment_no = v_payment_no;
        GET DIAGNOSTICS v_tmp = ROW_COUNT;
        v_count := v_count + v_tmp;
    END IF;
    RAISE NOTICE '已删 payment_orders: % 行', v_count;

    -- 5. 订单本身
    DELETE FROM public.orders WHERE id = v_order_id;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RAISE NOTICE '已删 orders: % 行', v_count;

    RAISE NOTICE '✅ 测试数据清理完成';
END $$;

-- 验证：应全部为 0
SELECT
    (SELECT COUNT(*) FROM public.orders WHERE order_no = 'TEST202607070001') AS orders_left,
    (SELECT COUNT(*) FROM public.escrow_records e
        WHERE e.order_id IN (SELECT id FROM public.orders WHERE order_no = 'TEST202607070001')) AS escrow_left,
    (SELECT COUNT(*) FROM public.payment_orders p
        WHERE p.business_id IN (SELECT id FROM public.orders WHERE order_no = 'TEST202607070001')
          AND p.business_type = 'order') AS payment_orders_left;
