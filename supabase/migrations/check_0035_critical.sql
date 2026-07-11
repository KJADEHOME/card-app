-- ============================================
-- 0035 关键对象确认（精简版）
-- ============================================

-- 1. 三张支付表
SELECT tablename AS 表名
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('payment_orders', 'escrow_records', 'platform_config')
ORDER BY tablename;

-- 2. 6 个支付 RPC
SELECT proname AS 函数名
FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN (
    'create_payment_order',
    'process_payment_success',
    'pay_with_balance',
    'escrow_release_to_seller',
    'escrow_refund_to_buyer',
    'escrow_auto_confirm'
  )
ORDER BY proname;

-- 3. 平台配置（看默认值）
SELECT key, value
FROM public.platform_config
WHERE key IN ('platform_fee_rate', 'auto_confirm_days', 'auto_cancel_hours')
ORDER BY key;
