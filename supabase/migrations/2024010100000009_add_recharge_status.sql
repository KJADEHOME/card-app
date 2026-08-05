-- ============================================
-- 优化人工充值流程：添加 status 字段 + 管理员审核支持
-- ============================================

-- 1. 给 wallet_transactions 添加 status 字段（兼容现有数据）
ALTER TABLE public.wallet_transactions ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'completed';

-- 更新历史充值记录的状态（根据 description 判断）
UPDATE public.wallet_transactions 
SET status = 'pending' 
WHERE type = 'deposit' AND description LIKE '%待审核%';

-- 创建索引
CREATE INDEX IF NOT EXISTS idx_wallet_tx_status ON public.wallet_transactions(status);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_type_status ON public.wallet_transactions(type, status);

-- 2. 添加管理员配置（把你的 Supabase 用户ID填入）
-- 注意：请把下面 'YOUR-ADMIN-UUID-HERE' 替换为你的实际管理员用户ID
INSERT INTO public.platform_config (key, value, description) VALUES
    ('admin_user_id', '45678987-ac1f-4f21-8973-9906d5b30de5', '管理员用户UUID，用于管理后台权限判断')
ON CONFLICT (key) DO NOTHING;

-- 3. 添加管理员 RLS 策略：管理员可以查看所有钱包流水
DROP POLICY IF EXISTS "Admin view all transactions" ON public.wallet_transactions;
CREATE POLICY "Admin view all transactions" ON public.wallet_transactions
    FOR SELECT USING (
        auth.uid() = (SELECT (value)::uuid FROM public.platform_config WHERE key = 'admin_user_id')
    );

-- 管理员也可以查看所有钱包
DROP POLICY IF EXISTS "Admin view all wallets" ON public.wallets;
CREATE POLICY "Admin view all wallets" ON public.wallets
    FOR SELECT USING (
        auth.uid() = (SELECT (value)::uuid FROM public.platform_config WHERE key = 'admin_user_id')
    );

-- 4. 创建管理员审核充值 RPC 函数
CREATE OR REPLACE FUNCTION approve_recharge(p_tx_id UUID, p_admin_uid UUID)
RETURNS JSONB AS $$
DECLARE
    v_tx public.wallet_transactions%ROWTYPE;
    v_wallet public.wallets%ROWTYPE;
    v_admin_id UUID;
BEGIN
    -- 获取配置的管理员ID
    SELECT (value)::uuid INTO v_admin_id FROM public.platform_config WHERE key = 'admin_user_id';
    
    -- 权限检查
    IF p_admin_uid IS NULL OR p_admin_uid != v_admin_id THEN
        RETURN jsonb_build_object('success', false, 'error', '无管理员权限');
    END IF;
    
    -- 获取交易记录
    SELECT * INTO v_tx FROM public.wallet_transactions WHERE id = p_tx_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '交易记录不存在');
    END IF;
    IF v_tx.status != 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', '该记录已处理');
    END IF;
    
    -- 获取钱包
    SELECT * INTO v_wallet FROM public.wallets WHERE id = v_tx.wallet_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '钱包不存在');
    END IF;
    
    -- 更新钱包余额（增加余额，同步更新 total_earned）
    UPDATE public.wallets 
    SET balance = balance + v_tx.amount,
        total_earned = COALESCE(total_earned, 0) + v_tx.amount,
        updated_at = NOW()
    WHERE id = v_wallet.id;
    
    -- 更新交易记录为已完成
    UPDATE public.wallet_transactions
    SET status = 'completed',
        description = REPLACE(description, '（待审核）', '（已到账）'),
        balance_after = v_wallet.balance + v_tx.amount
    WHERE id = p_tx_id;
    
    RETURN jsonb_build_object('success', true, 'message', '充值已确认到账');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. 创建拒绝充值 RPC 函数
CREATE OR REPLACE FUNCTION reject_recharge(p_tx_id UUID, p_admin_uid UUID, p_reason TEXT DEFAULT '充值审核未通过')
RETURNS JSONB AS $$
DECLARE
    v_admin_id UUID;
BEGIN
    SELECT (value)::uuid INTO v_admin_id FROM public.platform_config WHERE key = 'admin_user_id';
    IF p_admin_uid IS NULL OR p_admin_uid != v_admin_id THEN
        RETURN jsonb_build_object('success', false, 'error', '无管理员权限');
    END IF;
    
    UPDATE public.wallet_transactions
    SET status = 'rejected',
        description = REPLACE(description, '（待审核）', '（已拒绝：' || p_reason || '）')
    WHERE id = p_tx_id AND status = 'pending';
    
    IF FOUND THEN
        RETURN jsonb_build_object('success', true, 'message', '已拒绝该充值申请');
    ELSE
        RETURN jsonb_build_object('success', false, 'error', '记录不存在或已处理');
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. 允许已登录用户插入 wallet_transactions（用于充值申请）
DROP POLICY IF EXISTS "Users insert own transactions" ON public.wallet_transactions;
CREATE POLICY "Users insert own transactions" ON public.wallet_transactions
    FOR INSERT WITH CHECK (auth.uid() = user_id);
