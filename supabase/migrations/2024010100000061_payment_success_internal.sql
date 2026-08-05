-- TASK-CR-0105-F: close the unverified third-party payment success path.
-- This migration is not deployed by this task.

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.payment_callbacks') IS NULL
     OR to_regclass('public.payment_orders') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.escrow_records') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_transactions') IS NULL THEN
    RAISE EXCEPTION '0061 requires payment callback, payment, order, escrow and wallet tables';
  END IF;
  IF to_regprocedure('public.process_payment_success(text,text,text,jsonb)') IS NULL THEN
    RAISE EXCEPTION '0061 requires legacy process_payment_success(text,text,text,jsonb)';
  END IF;
  IF to_regprocedure('public.process_payment_success(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION '0061 expected process_payment_success(uuid) to be absent';
  END IF;
END;
$$;

-- Remove the caller-controlled provider success entry point before creating
-- the callback-id-only internal entry point.
REVOKE ALL ON FUNCTION public.process_payment_success(TEXT, TEXT, TEXT, JSONB)
  FROM PUBLIC, anon, authenticated, service_role;
DROP FUNCTION public.process_payment_success(TEXT, TEXT, TEXT, JSONB);

CREATE FUNCTION public.process_payment_success(p_callback_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_callback public.payment_callbacks%ROWTYPE;
  v_payment public.payment_orders%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_escrow public.escrow_records%ROWTYPE;
  v_wallet public.wallets%ROWTYPE;
  v_fee_rate NUMERIC;
  v_platform_fee NUMERIC(12,2);
  v_seller_amount NUMERIC(12,2);
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'SERVICE_ROLE_REQUIRED',
      'error', 'Service role required'
    );
  END IF;

  SELECT *
  INTO v_callback
  FROM public.payment_callbacks
  WHERE id = p_callback_id
  FOR UPDATE;

  IF v_callback.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'CALLBACK_NOT_FOUND');
  END IF;

  IF v_callback.verify_status <> 'verified' OR v_callback.verified_at IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'CALLBACK_NOT_VERIFIED');
  END IF;

  IF v_callback.callback_status = 'processed' THEN
    SELECT *
    INTO v_payment
    FROM public.payment_orders
    WHERE payment_no = v_callback.payment_no;

    IF v_payment.id IS NULL
       OR v_payment.status <> 'paid'
       OR v_payment.provider IS DISTINCT FROM v_callback.provider
       OR v_payment.trade_no IS DISTINCT FROM v_callback.trade_no THEN
      RAISE EXCEPTION '0061 processed callback % has inconsistent payment state', p_callback_id;
    END IF;

    IF v_payment.business_type = 'order' THEN
      SELECT *
      INTO v_escrow
      FROM public.escrow_records
      WHERE payment_order_id = v_payment.id;

      IF v_escrow.id IS NULL
         OR v_escrow.order_id IS DISTINCT FROM v_payment.business_id
         OR v_escrow.status NOT IN ('frozen', 'released', 'refunded', 'disputed') THEN
        RAISE EXCEPTION '0061 processed callback % has inconsistent escrow state', p_callback_id;
      END IF;
    END IF;

    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'callback_id', v_callback.id,
      'payment_no', v_callback.payment_no
    );
  END IF;

  IF v_callback.callback_status <> 'pending' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'CALLBACK_NOT_SETTLEABLE',
      'status', v_callback.callback_status
    );
  END IF;

  SELECT *
  INTO v_payment
  FROM public.payment_orders
  WHERE payment_no = v_callback.payment_no
  FOR UPDATE;

  IF v_payment.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'PAYMENT_NOT_FOUND');
  END IF;

  IF v_payment.provider IS DISTINCT FROM v_callback.provider
     OR v_payment.amount IS DISTINCT FROM v_callback.amount THEN
    RETURN jsonb_build_object('success', false, 'code', 'PAYMENT_CALLBACK_MISMATCH');
  END IF;

  IF v_payment.provider NOT IN ('alipay', 'wechat') THEN
    RETURN jsonb_build_object('success', false, 'code', 'PROVIDER_NOT_EXTERNAL');
  END IF;

  IF v_payment.status = 'paid' THEN
    RETURN jsonb_build_object('success', false, 'code', 'PAYMENT_ALREADY_SETTLED');
  END IF;

  IF v_payment.status <> 'pending' THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'PAYMENT_NOT_SETTLEABLE',
      'status', v_payment.status
    );
  END IF;

  IF v_payment.business_type = 'recharge' THEN
    IF v_callback.order_id IS NOT NULL OR v_callback.currency <> 'CNY' THEN
      RETURN jsonb_build_object('success', false, 'code', 'RECHARGE_CALLBACK_MISMATCH');
    END IF;

    INSERT INTO public.wallets(user_id, balance, total_income)
    VALUES(v_payment.user_id, v_payment.amount, v_payment.amount)
    ON CONFLICT (user_id) DO UPDATE
    SET balance = public.wallets.balance + EXCLUDED.balance,
        total_income = public.wallets.total_income + EXCLUDED.total_income,
        updated_at = NOW();

    SELECT *
    INTO v_wallet
    FROM public.wallets
    WHERE user_id = v_payment.user_id
    FOR UPDATE;

    INSERT INTO public.wallet_transactions(
      wallet_id, user_id, type, amount, balance_after, description
    )
    VALUES(
      v_wallet.id, v_payment.user_id, 'recharge', v_payment.amount,
      v_wallet.balance, v_callback.provider || ' recharge ' || v_payment.payment_no
    );

    INSERT INTO public.notifications(user_id, type, title, content)
    VALUES(
      v_payment.user_id, 'recharge_success', 'Recharge successful',
      v_callback.provider || ' recharge ' || v_payment.amount || ' CNY credited'
    );

  ELSIF v_payment.business_type = 'order' THEN
    SELECT *
    INTO v_order
    FROM public.orders
    WHERE id = v_payment.business_id
    FOR UPDATE;

    IF v_order.id IS NULL
       OR v_callback.order_id IS DISTINCT FROM v_order.id
       OR v_order.buyer_id IS DISTINCT FROM v_payment.user_id
       OR v_order.total_amount IS DISTINCT FROM v_payment.amount
       OR COALESCE(v_order.currency, 'CNY') IS DISTINCT FROM v_callback.currency THEN
      RETURN jsonb_build_object('success', false, 'code', 'ORDER_CALLBACK_MISMATCH');
    END IF;

    IF v_order.status NOT IN ('pending', 'pending_payment') THEN
      RETURN jsonb_build_object(
        'success', false,
        'code', 'ORDER_NOT_SETTLEABLE',
        'status', v_order.status
      );
    END IF;

    SELECT *
    INTO v_escrow
    FROM public.escrow_records
    WHERE order_id = v_order.id
    FOR UPDATE;

    IF v_escrow.id IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'code', 'ESCROW_ALREADY_EXISTS');
    END IF;

    SELECT value::NUMERIC
    INTO v_fee_rate
    FROM public.platform_config
    WHERE key = 'platform_fee_rate';
    v_fee_rate := COALESCE(v_fee_rate, 0.03);
    v_platform_fee := ROUND(v_order.total_amount * v_fee_rate, 2);
    v_seller_amount := v_order.total_amount - v_platform_fee;

    UPDATE public.orders
    SET status = 'paid',
        payment_method = v_callback.provider,
        payment_at = NOW(),
        payment_no = v_payment.payment_no,
        platform_fee = v_platform_fee,
        seller_amount = v_seller_amount,
        updated_at = NOW()
    WHERE id = v_order.id;

    INSERT INTO public.escrow_records(
      order_id, payment_order_id, buyer_id, seller_id,
      total_amount, platform_fee, seller_amount,
      payment_provider, status, frozen_at
    )
    VALUES(
      v_order.id, v_payment.id, v_order.buyer_id, v_order.seller_id,
      v_order.total_amount, v_platform_fee, v_seller_amount,
      v_callback.provider, 'frozen', NOW()
    );

    INSERT INTO public.notifications(user_id, type, title, content, related_id)
    VALUES(
      v_order.seller_id, 'order_paid', 'Order paid',
      'Order ' || v_order.order_no || ' payment verified and held in escrow',
      v_order.id
    );
  ELSE
    RETURN jsonb_build_object('success', false, 'code', 'BUSINESS_TYPE_UNSUPPORTED');
  END IF;

  UPDATE public.payment_orders
  SET status = 'paid',
      trade_no = v_callback.trade_no,
      callback_raw = v_callback.raw_payload,
      paid_at = NOW(),
      updated_at = NOW()
  WHERE id = v_payment.id
    AND status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION '0061 payment % lost pending state during settlement', v_payment.id;
  END IF;

  UPDATE public.payment_callbacks
  SET callback_status = 'processed',
      processed_at = NOW()
  WHERE id = v_callback.id
    AND verify_status = 'verified'
    AND callback_status = 'pending';

  IF NOT FOUND THEN
    RAISE EXCEPTION '0061 callback % lost verified pending state during settlement', v_callback.id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', false,
    'callback_id', v_callback.id,
    'payment_no', v_payment.payment_no,
    'business_type', v_payment.business_type
  );
END;
$$;

REVOKE ALL ON FUNCTION public.process_payment_success(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_payment_success(UUID)
  TO service_role;

COMMENT ON FUNCTION public.process_payment_success(UUID) IS
  'CR-0105-F internal service-role-only atomic settlement for one verified payment callback ID.';

COMMIT;