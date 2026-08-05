-- TASK-CR-0104-R: harden the existing balance-payment and escrow flow.
-- Scope: pay_with_balance(UUID) only. Marketplace order creation is unchanged.

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.pay_with_balance(uuid)') IS NULL THEN
    RAISE EXCEPTION '0055 requires public.pay_with_balance(uuid)';
  END IF;
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.payment_orders') IS NULL
     OR to_regclass('public.escrow_records') IS NULL
     OR to_regclass('public.wallet_transactions') IS NULL
     OR to_regclass('public.notifications') IS NULL
     OR to_regclass('public.platform_config') IS NULL THEN
    RAISE EXCEPTION '0055 payment/escrow prerequisites are missing';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.pay_with_balance(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_order public.orders%ROWTYPE;
  v_wallet public.wallets%ROWTYPE;
  v_fee_rate NUMERIC;
  v_platform_fee NUMERIC(12,2);
  v_seller_amount NUMERIC(12,2);
  v_payment_no TEXT;
  v_payment_order_id UUID;
  v_wallet_rows INTEGER;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'AUTHENTICATION_REQUIRED',
      'error', 'Authentication required'
    );
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL OR v_order.buyer_id IS DISTINCT FROM v_actor THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ORDER_UNAVAILABLE',
      'error', 'Order unavailable'
    );
  END IF;

  IF v_order.status NOT IN ('pending', 'pending_payment') THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'ORDER_NOT_PAYABLE',
      'error', 'Order status does not allow payment',
      'status', v_order.status
    );
  END IF;

  IF v_order.seller_id IS NULL
     OR v_order.total_amount IS NULL
     OR v_order.total_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INVALID_ORDER',
      'error', 'Order payment data is invalid'
    );
  END IF;

  SELECT *
  INTO v_wallet
  FROM public.wallets
  WHERE user_id = v_actor
  FOR UPDATE;

  IF v_wallet.id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'WALLET_NOT_FOUND',
      'error', 'Wallet not found'
    );
  END IF;

  IF v_wallet.balance < v_order.total_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'INSUFFICIENT_BALANCE',
      'error', 'Insufficient balance',
      'balance', v_wallet.balance,
      'required', v_order.total_amount
    );
  END IF;

  SELECT COALESCE(value::NUMERIC, 0.03)
  INTO v_fee_rate
  FROM public.platform_config
  WHERE key = 'platform_fee_rate';
  v_fee_rate := COALESCE(v_fee_rate, 0.03);
  v_platform_fee := ROUND(v_order.total_amount * v_fee_rate, 2);
  v_seller_amount := v_order.total_amount - v_platform_fee;
  v_payment_no := 'PAY'
    || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')
    || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6));

  UPDATE public.wallets
  SET balance = balance - v_order.total_amount,
      frozen_balance = frozen_balance + v_order.total_amount,
      total_expense = total_expense + v_order.total_amount,
      updated_at = NOW()
  WHERE id = v_wallet.id
    AND balance >= v_order.total_amount;
  GET DIAGNOSTICS v_wallet_rows = ROW_COUNT;

  IF v_wallet_rows <> 1 THEN
    RAISE EXCEPTION '0055 wallet balance changed unexpectedly for order %', p_order_id;
  END IF;

  UPDATE public.orders
  SET status = 'paid',
      payment_method = 'balance',
      payment_at = NOW(),
      payment_no = v_payment_no,
      platform_fee = v_platform_fee,
      seller_amount = v_seller_amount,
      updated_at = NOW()
  WHERE id = p_order_id;

  INSERT INTO public.payment_orders (
    payment_no, business_type, business_id, user_id,
    provider, amount, subject, status, paid_at
  ) VALUES (
    v_payment_no, 'order', p_order_id, v_actor,
    'balance', v_order.total_amount,
    'Balance payment: ' || v_order.order_no, 'paid', NOW()
  )
  RETURNING id INTO v_payment_order_id;

  INSERT INTO public.escrow_records (
    order_id, payment_order_id, buyer_id, seller_id,
    total_amount, platform_fee, seller_amount,
    payment_provider, status, frozen_at
  ) VALUES (
    p_order_id, v_payment_order_id, v_actor, v_order.seller_id,
    v_order.total_amount, v_platform_fee, v_seller_amount,
    'balance', 'frozen', NOW()
  );

  INSERT INTO public.wallet_transactions (
    wallet_id, user_id, order_id, type,
    amount, balance_after, description
  ) VALUES (
    v_wallet.id, v_actor, p_order_id, 'payment',
    v_order.total_amount, v_wallet.balance - v_order.total_amount,
    'Balance payment order: ' || v_order.order_no
  );

  INSERT INTO public.notifications (
    user_id, type, title, content, related_id
  ) VALUES (
    v_order.seller_id, 'order_paid', 'Buyer payment received',
    'Order ' || v_order.order_no || ' is paid and funds are held in escrow',
    p_order_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'payment_no', v_payment_no,
    'payment_order_id', v_payment_order_id,
    'order_id', p_order_id,
    'order_status', 'paid',
    'escrow_status', 'frozen',
    'balance_after', v_wallet.balance - v_order.total_amount
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pay_with_balance(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pay_with_balance(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.pay_with_balance(UUID) TO authenticated;

COMMENT ON FUNCTION public.pay_with_balance(UUID) IS
  'CR-0104-R: authenticated, serialized balance payment that atomically creates linked payment and escrow records.';

COMMIT;
