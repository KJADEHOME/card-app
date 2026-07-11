-- ============================================
-- 卡域支付系统 - 0035 执行状态检查
-- 在 Supabase SQL Editor 跑这段，看输出判断是否已执行 0035
-- ============================================

-- 1. 检查三张表是否存在
SELECT tablename AS 表名
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('payment_orders', 'escrow_records', 'platform_config')
ORDER BY tablename;
-- 预期: 3 行 = 已执行; 0 行 = 未执行


-- 2. 检查 6 个 RPC 函数是否存在
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
-- 预期: 6 行 = 已执行; 0 行 = 未执行


-- 3. 检查 platform_config 配置项
SELECT key, value, description
FROM public.platform_config
ORDER BY key;
-- 预期: platform_fee_rate / auto_confirm_days / auto_cancel_hours 三行


-- 4. 表行数概览（确认表能正常访问）
SELECT 'payment_orders' AS 表, count(*) AS 行数 FROM public.payment_orders
UNION ALL
SELECT 'escrow_records', count(*) FROM public.escrow_records
UNION ALL
SELECT 'platform_config', count(*) FROM public.platform_config;
