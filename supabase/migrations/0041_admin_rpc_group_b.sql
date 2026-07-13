-- 0041_admin_rpc_group_b.sql
-- SH-003C Phase 3 Group B: secure recharge approval/rejection RPCs
BEGIN;

CREATE OR REPLACE FUNCTION public.approve_recharge(p_tx_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_admin_id UUID;
    v_tx public.wallet_transactions%ROWTYPE;
    v_wallet public.wallets%ROWTYPE;
BEGIN
    v_admin_id := public.require_admin();
    IF p_tx_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '交易ID不能为空');
    END IF;

    SELECT * INTO v_tx
      FROM public.wallet_transactions
     WHERE id = p_tx_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '交易记录不存在');
    END IF;
    IF v_tx.type <> 'deposit' OR v_tx.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', '记录不是待审核充值或已处理');
    END IF;
    IF v_tx.amount IS NULL OR v_tx.amount <= 0 THEN
        RETURN jsonb_build_object('success', false, 'error', '充值金额不合法');
    END IF;

    SELECT * INTO v_wallet
      FROM public.wallets
     WHERE id = v_tx.wallet_id
     FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '钱包不存在');
    END IF;

    UPDATE public.wallets
       SET balance = balance + v_tx.amount,
           total_earned = COALESCE(total_earned, 0) + v_tx.amount,
           updated_at = NOW()
     WHERE id = v_wallet.id;

    UPDATE public.wallet_transactions
       SET status = 'completed',
           description = REPLACE(COALESCE(description,''), '（待审核）', '（已到账）'),
           balance_after = v_wallet.balance + v_tx.amount
     WHERE id = p_tx_id AND status = 'pending';

    PERFORM public.log_admin_action('approve_recharge', 'wallet_transaction', p_tx_id,
        jsonb_build_object('amount', v_tx.amount, 'user_id', v_tx.user_id));
    RETURN jsonb_build_object('success', true, 'message', '充值已确认到账');
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_recharge(
    p_tx_id UUID,
    p_reason TEXT DEFAULT '充值审核未通过'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_admin_id UUID;
    v_tx public.wallet_transactions%ROWTYPE;
    v_reason TEXT;
BEGIN
    v_admin_id := public.require_admin();
    v_reason := LEFT(BTRIM(COALESCE(p_reason, '充值审核未通过')), 500);

    SELECT * INTO v_tx
      FROM public.wallet_transactions
     WHERE id = p_tx_id
     FOR UPDATE;
    IF NOT FOUND OR v_tx.type <> 'deposit' OR v_tx.status <> 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', '记录不存在、类型错误或已处理');
    END IF;

    UPDATE public.wallet_transactions
       SET status = 'rejected',
           description = REPLACE(COALESCE(description,''), '（待审核）', '（已拒绝：' || v_reason || '）')
     WHERE id = p_tx_id AND status = 'pending';

    PERFORM public.log_admin_action('reject_recharge', 'wallet_transaction', p_tx_id,
        jsonb_build_object('reason', v_reason, 'amount', v_tx.amount, 'user_id', v_tx.user_id));
    RETURN jsonb_build_object('success', true, 'message', '已拒绝该充值申请');
END;
$$;

REVOKE ALL ON FUNCTION public.approve_recharge(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_recharge(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.reject_recharge(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reject_recharge(UUID,TEXT) TO authenticated;

-- Disable legacy overloads that trusted a frontend-supplied administrator UUID.
REVOKE ALL ON FUNCTION public.approve_recharge(UUID,UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reject_recharge(UUID,UUID,TEXT) FROM PUBLIC, anon, authenticated;

COMMIT;
