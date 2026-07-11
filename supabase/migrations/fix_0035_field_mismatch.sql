-- ============================================
-- 修复 0035 RPC 与 0006 表定义的字段名不匹配
-- ============================================
-- 问题清单:
--   1. wallets 表: 0006 用 total_earned/total_spent, 0035 RPC 用 total_income/total_expense
--   2. wallet_transactions 表: 0006 用 reference_id, 0035 用 order_id, 0018 用 related_id
--   3. wallet_transactions type CHECK: 0006 不含 payment/recharge 等 0035 新增类型
--   4. orders 表缺: payment_method / payment_no / payment_at / platform_fee / seller_amount
--      (0006 只有 paid_at / seller_earnings), 0035 RPC 全部要更新
--   5. orders 字段名: 0006 用 seller_earnings, 0035 用 seller_amount
--
-- 方案: 加兼容列 + 扩展 CHECK 约束，旧代码和新代码都能跑
-- 执行方式: Supabase SQL Editor 整段执行（幂等，可以重跑）
-- ============================================

-- ==========================================
-- 0. orders 表: 补全 0035 RPC 需要的全部字段
-- ==========================================
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payment_method TEXT;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payment_no TEXT;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payment_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS platform_fee NUMERIC(12,2) DEFAULT 0;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS seller_amount NUMERIC(12,2) DEFAULT 0;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS refunded_at TIMESTAMP WITH TIME ZONE;

-- 把旧的 seller_earnings 同步到 seller_amount
UPDATE public.orders
SET seller_amount = seller_earnings
WHERE seller_amount = 0 AND seller_earnings > 0;

-- 触发器: seller_earnings 与 seller_amount 双向同步
CREATE OR REPLACE FUNCTION public.sync_order_seller_amount()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.seller_amount := COALESCE(NEW.seller_amount, NEW.seller_earnings, 0);
    NEW.seller_earnings := NEW.seller_amount;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_order_seller_amount_trigger ON public.orders;
CREATE TRIGGER sync_order_seller_amount_trigger
    BEFORE INSERT OR UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION public.sync_order_seller_amount();

-- 索引
CREATE INDEX IF NOT EXISTS idx_orders_payment_no ON public.orders(payment_no);
CREATE INDEX IF NOT EXISTS idx_orders_payment_method ON public.orders(payment_method);


-- ==========================================
-- 0.5 orders 表: 扩展 status CHECK 约束（加 pending_payment）
-- ==========================================
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_status_check;
ALTER TABLE public.orders DROP CONSTRAINT IF EXISTS orders_status_check1;

ALTER TABLE public.orders ADD CONSTRAINT orders_status_check
    CHECK (status IN (
        'pending', 'pending_payment', 'paid', 'shipped', 'delivered',
        'completed', 'cancelled', 'refund_requested', 'refunded', 'disputed'
    ));


-- ==========================================
-- 1. wallets 表: 加 total_income / total_expense / updated_at 兼容列
-- ==========================================
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS total_income NUMERIC(14,2) DEFAULT 0;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS total_expense NUMERIC(14,2) DEFAULT 0;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW();

-- 把旧字段数据同步到新字段
UPDATE public.wallets
SET total_income = total_earned
WHERE total_earned IS NOT NULL AND (total_income IS NULL OR total_income = 0);

UPDATE public.wallets
SET total_expense = total_spent
WHERE total_spent IS NOT NULL AND (total_expense IS NULL OR total_expense = 0);

-- 触发器: 双向同步 total_earned/total_spent 与 total_income/total_expense
CREATE OR REPLACE FUNCTION public.sync_wallet_totals()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.total_income := COALESCE(NEW.total_income, NEW.total_earned, 0);
    NEW.total_expense := COALESCE(NEW.total_expense, NEW.total_spent, 0);
    NEW.total_earned := NEW.total_income;
    NEW.total_spent := NEW.total_expense;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_wallet_totals_trigger ON public.wallets;
CREATE TRIGGER sync_wallet_totals_trigger
    BEFORE INSERT OR UPDATE ON public.wallets
    FOR EACH ROW EXECUTE FUNCTION public.sync_wallet_totals();


-- ==========================================
-- 2. wallet_transactions 表: 加 order_id / related_id 兼容列
-- ==========================================
ALTER TABLE public.wallet_transactions ADD COLUMN IF NOT EXISTS order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL;
ALTER TABLE public.wallet_transactions ADD COLUMN IF NOT EXISTS related_id UUID;


-- ==========================================
-- 3. wallet_transactions: 扩展 type CHECK 约束
-- ==========================================
ALTER TABLE public.wallet_transactions DROP CONSTRAINT IF EXISTS wallet_transactions_type_check;
ALTER TABLE public.wallet_transactions DROP CONSTRAINT IF EXISTS wallet_transactions_type_check1;

ALTER TABLE public.wallet_transactions ADD CONSTRAINT wallet_transactions_type_check
    CHECK (type IN (
        'deposit', 'withdrawal', 'sale', 'purchase', 'refund', 'fee', 'reward',
        'payment', 'recharge'
    ));


-- ==========================================
-- 4. 验证修复结果
-- ==========================================
SELECT '=== orders 表字段 ===' AS info;
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'orders'
  AND column_name IN ('payment_method', 'payment_no', 'payment_at', 'platform_fee',
                      'seller_amount', 'seller_earnings', 'refunded_at', 'paid_at')
ORDER BY column_name;

SELECT '=== wallets 表字段 ===' AS info;
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'wallets'
  AND column_name IN ('balance', 'frozen_balance', 'total_earned', 'total_spent',
                      'total_income', 'total_expense')
ORDER BY column_name;

SELECT '=== wallet_transactions type CHECK ===' AS info;
SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.wallet_transactions'::regclass
  AND contype = 'c' AND conname = 'wallet_transactions_type_check';

SELECT '✅ 字段名不匹配修复完成（已包含 orders 表补全）' AS done;
