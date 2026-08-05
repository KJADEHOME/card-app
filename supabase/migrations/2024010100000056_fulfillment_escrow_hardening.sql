-- TASK-CR-0104-S: harden shipment, escrow release/refund and timeout settlement.
-- Does not modify create_marketplace_order() or pay_with_balance().

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.seller_ship_order(uuid,text,text)') IS NULL
     OR to_regprocedure('public.escrow_release_to_seller(uuid)') IS NULL
     OR to_regprocedure('public.escrow_refund_to_buyer(uuid,text)') IS NULL
     OR to_regprocedure('public.escrow_auto_confirm()') IS NULL THEN
    RAISE EXCEPTION '0056 required fulfillment/escrow functions are missing';
  END IF;
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.consignments') IS NULL
     OR to_regclass('public.escrow_records') IS NULL
     OR to_regclass('public.wallets') IS NULL
     OR to_regclass('public.wallet_transactions') IS NULL
     OR to_regclass('public.platform_fees') IS NULL THEN
    RAISE EXCEPTION '0056 required fulfillment/settlement tables are missing';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.seller_ship_order(
  p_order_id UUID,
  p_tracking_no TEXT,
  p_shipping_carrier TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_order public.orders%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'AUTHENTICATION_REQUIRED', 'error', 'Authentication required');
  END IF;
  IF NULLIF(btrim(p_tracking_no), '') IS NULL OR length(p_tracking_no) > 100 THEN
    RETURN jsonb_build_object('success', false, 'code', 'INVALID_TRACKING', 'error', 'Valid tracking number required');
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL OR v_order.seller_id IS DISTINCT FROM v_actor THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_UNAVAILABLE', 'error', 'Order unavailable');
  END IF;
  IF v_order.status <> 'paid' THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_NOT_SHIPPABLE', 'error', 'Order status does not allow shipment', 'status', v_order.status);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.escrow_records e
    WHERE e.order_id = p_order_id AND e.status = 'frozen'
  ) THEN
    RETURN jsonb_build_object('success', false, 'code', 'ESCROW_NOT_FROZEN', 'error', 'Frozen escrow required before shipment');
  END IF;

  UPDATE public.orders
  SET status = 'shipped', tracking_no = btrim(p_tracking_no),
      shipping_carrier = NULLIF(btrim(p_shipping_carrier), ''),
      shipped_at = NOW(), updated_at = NOW()
  WHERE id = p_order_id;

  INSERT INTO public.notifications(user_id, type, title, content, related_id)
  VALUES (v_order.buyer_id, 'order_shipped', 'Order shipped',
          'Order ' || v_order.order_no || ' has shipped', p_order_id);

  RETURN jsonb_build_object('success', true, 'order_id', p_order_id, 'status', 'shipped', 'tracking_no', btrim(p_tracking_no));
END;
$$;

CREATE OR REPLACE FUNCTION public.escrow_release_to_seller(p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_order public.orders%ROWTYPE;
  v_escrow public.escrow_records%ROWTYPE;
  v_wallet_rows INTEGER;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'AUTHENTICATION_REQUIRED', 'error', 'Authentication required');
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL OR v_order.buyer_id IS DISTINCT FROM v_actor THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_UNAVAILABLE', 'error', 'Order unavailable');
  END IF;
  IF v_order.status NOT IN ('shipped', 'delivered') THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_NOT_CONFIRMABLE', 'error', 'Order status does not allow receipt confirmation', 'status', v_order.status);
  END IF;

  SELECT * INTO v_escrow FROM public.escrow_records WHERE order_id = p_order_id FOR UPDATE;
  IF v_escrow.id IS NULL OR v_escrow.status <> 'frozen' THEN
    RETURN jsonb_build_object('success', false, 'code', 'ESCROW_NOT_FROZEN', 'error', 'Frozen escrow unavailable');
  END IF;

  IF v_escrow.payment_provider = 'balance' THEN
    UPDATE public.wallets
    SET frozen_balance = frozen_balance - v_escrow.total_amount, updated_at = NOW()
    WHERE user_id = v_escrow.buyer_id
      AND frozen_balance >= v_escrow.total_amount;
    GET DIAGNOSTICS v_wallet_rows = ROW_COUNT;
    IF v_wallet_rows <> 1 THEN
      RAISE EXCEPTION '0056 buyer frozen balance mismatch for order %', p_order_id;
    END IF;
  END IF;

  INSERT INTO public.wallets(user_id, balance, total_income)
  VALUES (v_escrow.seller_id, v_escrow.seller_amount, v_escrow.seller_amount)
  ON CONFLICT (user_id) DO UPDATE
  SET balance = public.wallets.balance + EXCLUDED.balance,
      total_income = public.wallets.total_income + EXCLUDED.total_income,
      updated_at = NOW();

  INSERT INTO public.wallet_transactions(wallet_id, user_id, order_id, type, amount, balance_after, description)
  SELECT w.id, v_escrow.seller_id, p_order_id, 'sale', v_escrow.seller_amount,
         w.balance, 'Order completed income: ' || v_order.order_no
  FROM public.wallets w WHERE w.user_id = v_escrow.seller_id;

  INSERT INTO public.platform_fees(
    order_id, consignment_id, fee_type, fee_amount, fee_pct, currency, description
  )
  SELECT p_order_id, v_order.consignment_id, 'transaction', v_escrow.platform_fee,
         CASE WHEN v_escrow.total_amount > 0 THEN ROUND(v_escrow.platform_fee / v_escrow.total_amount * 100, 2) ELSE 0 END,
         COALESCE(v_order.currency, 'CNY'), 'Escrow release commission'
  WHERE v_escrow.platform_fee > 0
    AND NOT EXISTS (SELECT 1 FROM public.platform_fees pf WHERE pf.order_id = p_order_id AND pf.fee_type = 'transaction');

  UPDATE public.escrow_records SET status = 'released', released_at = NOW() WHERE id = v_escrow.id;
  UPDATE public.orders
  SET status = 'completed', delivered_at = COALESCE(delivered_at, NOW()),
      completed_at = NOW(), updated_at = NOW()
  WHERE id = p_order_id;
  UPDATE public.consignments
  SET status = 'sold', sold_at = COALESCE(sold_at, NOW()), updated_at = NOW()
  WHERE id = v_order.consignment_id;

  INSERT INTO public.notifications(user_id, type, title, content, related_id)
  VALUES (v_escrow.seller_id, 'order_completed', 'Order completed',
          'Order ' || v_order.order_no || ' completed; escrow released', p_order_id);

  RETURN jsonb_build_object('success', true, 'order_status', 'completed',
    'escrow_status', 'released', 'seller_amount', v_escrow.seller_amount,
    'platform_fee', v_escrow.platform_fee);
END;
$$;

CREATE OR REPLACE FUNCTION public.escrow_refund_to_buyer(
  p_order_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_role TEXT := auth.role();
  v_order public.orders%ROWTYPE;
  v_escrow public.escrow_records%ROWTYPE;
  v_wallet_rows INTEGER;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_UNAVAILABLE', 'error', 'Order unavailable');
  END IF;
  IF v_role IS DISTINCT FROM 'service_role'
     AND (v_actor IS NULL OR (v_actor IS DISTINCT FROM v_order.buyer_id AND v_actor IS DISTINCT FROM v_order.seller_id)) THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_UNAVAILABLE', 'error', 'Order unavailable');
  END IF;
  IF v_order.status NOT IN ('paid', 'shipped', 'delivered', 'refund_requested', 'disputed') THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_NOT_REFUNDABLE', 'error', 'Order status does not allow refund', 'status', v_order.status);
  END IF;

  SELECT * INTO v_escrow FROM public.escrow_records WHERE order_id = p_order_id FOR UPDATE;
  IF v_escrow.id IS NULL OR v_escrow.status <> 'frozen' THEN
    RETURN jsonb_build_object('success', false, 'code', 'ESCROW_NOT_FROZEN', 'error', 'Frozen escrow unavailable');
  END IF;

  IF v_escrow.payment_provider = 'balance' THEN
    UPDATE public.wallets
    SET frozen_balance = frozen_balance - v_escrow.total_amount,
        balance = balance + v_escrow.total_amount, updated_at = NOW()
    WHERE user_id = v_escrow.buyer_id
      AND frozen_balance >= v_escrow.total_amount;
    GET DIAGNOSTICS v_wallet_rows = ROW_COUNT;
    IF v_wallet_rows <> 1 THEN
      RAISE EXCEPTION '0056 buyer frozen balance mismatch for refund order %', p_order_id;
    END IF;
  ELSE
    INSERT INTO public.wallets(user_id, balance, total_income)
    VALUES (v_escrow.buyer_id, v_escrow.total_amount, v_escrow.total_amount)
    ON CONFLICT (user_id) DO UPDATE
    SET balance = public.wallets.balance + EXCLUDED.balance,
        total_income = public.wallets.total_income + EXCLUDED.total_income,
        updated_at = NOW();
  END IF;

  INSERT INTO public.wallet_transactions(wallet_id, user_id, order_id, type, amount, balance_after, description)
  SELECT w.id, v_escrow.buyer_id, p_order_id, 'refund', v_escrow.total_amount,
         w.balance, 'Order refund: ' || v_order.order_no
  FROM public.wallets w WHERE w.user_id = v_escrow.buyer_id;

  UPDATE public.escrow_records SET status = 'refunded', refunded_at = NOW() WHERE id = v_escrow.id;
  UPDATE public.payment_orders SET status = 'refunded' WHERE id = v_escrow.payment_order_id;
  UPDATE public.orders SET status = 'refunded', refunded_at = NOW(), updated_at = NOW() WHERE id = p_order_id;
  UPDATE public.consignments SET status = 'active', sold_at = NULL, updated_at = NOW()
  WHERE id = v_order.consignment_id AND status = 'reserved';

  RETURN jsonb_build_object('success', true, 'order_status', 'refunded',
    'escrow_status', 'refunded', 'refund_amount', v_escrow.total_amount,
    'reason', p_reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.escrow_auto_confirm()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_days INTEGER;
  v_count INTEGER := 0;
  r RECORD;
  v_wallet_rows INTEGER;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RETURN jsonb_build_object('success', false, 'code', 'SERVICE_ROLE_REQUIRED', 'error', 'Service role required');
  END IF;
  SELECT value::INTEGER INTO v_days FROM public.platform_config WHERE key = 'auto_confirm_days';
  v_days := COALESCE(v_days, 7);

  FOR r IN
    SELECT e.*, o.order_no, o.shipped_at, o.consignment_id, o.currency
    FROM public.escrow_records e JOIN public.orders o ON o.id = e.order_id
    WHERE e.status = 'frozen' AND o.status = 'shipped' AND o.shipped_at IS NOT NULL
      AND o.shipped_at < NOW() - (v_days || ' days')::INTERVAL
    FOR UPDATE OF e, o SKIP LOCKED
  LOOP
    IF r.payment_provider = 'balance' THEN
      UPDATE public.wallets
      SET frozen_balance = frozen_balance - r.total_amount, updated_at = NOW()
      WHERE user_id = r.buyer_id AND frozen_balance >= r.total_amount;
      GET DIAGNOSTICS v_wallet_rows = ROW_COUNT;
      IF v_wallet_rows <> 1 THEN
        RAISE EXCEPTION '0056 buyer frozen balance mismatch for auto-confirm order %', r.order_id;
      END IF;
    END IF;

    INSERT INTO public.wallets(user_id, balance, total_income)
    VALUES (r.seller_id, r.seller_amount, r.seller_amount)
    ON CONFLICT (user_id) DO UPDATE
    SET balance = public.wallets.balance + EXCLUDED.balance,
        total_income = public.wallets.total_income + EXCLUDED.total_income,
        updated_at = NOW();
    INSERT INTO public.wallet_transactions(wallet_id, user_id, order_id, type, amount, balance_after, description)
    SELECT w.id, r.seller_id, r.order_id, 'sale', r.seller_amount,
           w.balance, 'Auto-confirm income: ' || r.order_no
    FROM public.wallets w WHERE w.user_id = r.seller_id;
    INSERT INTO public.platform_fees(order_id, consignment_id, fee_type, fee_amount, fee_pct, currency, description)
    SELECT r.order_id, r.consignment_id, 'transaction', r.platform_fee,
           CASE WHEN r.total_amount > 0 THEN ROUND(r.platform_fee / r.total_amount * 100, 2) ELSE 0 END,
           COALESCE(r.currency, 'CNY'), 'Auto-confirm escrow commission'
    WHERE r.platform_fee > 0
      AND NOT EXISTS (SELECT 1 FROM public.platform_fees pf WHERE pf.order_id = r.order_id AND pf.fee_type = 'transaction');
    UPDATE public.escrow_records
    SET status = 'released', released_at = NOW(), auto_confirmed = TRUE WHERE id = r.id;
    UPDATE public.orders SET status = 'completed', completed_at = NOW(), updated_at = NOW() WHERE id = r.order_id;
    UPDATE public.consignments SET status = 'sold', sold_at = COALESCE(sold_at, NOW()), updated_at = NOW()
    WHERE id = r.consignment_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'auto_confirmed_count', v_count);
END;
$$;

REVOKE ALL ON FUNCTION public.seller_ship_order(UUID, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.seller_ship_order(UUID, TEXT, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.escrow_release_to_seller(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.escrow_release_to_seller(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.escrow_refund_to_buyer(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.escrow_refund_to_buyer(UUID, TEXT) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.escrow_auto_confirm() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.escrow_auto_confirm() TO service_role;

COMMIT;
