-- TASK-CR-0104-T-FIX: remove the invalid orders.listing_id reference from cancel_order.
-- 0057 remains immutable; this migration replaces only public.cancel_order(uuid).

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.cancel_order(uuid)') IS NULL THEN
    RAISE EXCEPTION '0058 requires public.cancel_order(uuid) from 0057';
  END IF;
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.escrow_records') IS NULL
     OR to_regclass('public.payment_orders') IS NULL
     OR to_regclass('public.consignments') IS NULL THEN
    RAISE EXCEPTION '0058 required order/escrow/consignment tables are missing';
  END IF;
  IF to_regprocedure('public.release_shop_order_stock(uuid,uuid,integer)') IS NULL THEN
    RAISE EXCEPTION '0058 requires public.release_shop_order_stock(uuid,uuid,integer)';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor UUID := auth.uid();
  v_order public.orders%ROWTYPE;
  v_escrow public.escrow_records%ROWTYPE;
  v_stock_result JSONB;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'code', 'AUTHENTICATION_REQUIRED', 'error', 'Authentication required');
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF v_order.id IS NULL
     OR (v_order.buyer_id IS DISTINCT FROM v_actor AND v_order.seller_id IS DISTINCT FROM v_actor) THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_UNAVAILABLE', 'error', 'Order unavailable');
  END IF;

  IF v_order.status = 'cancelled' THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'order_id', p_order_id, 'status', 'cancelled');
  END IF;

  SELECT * INTO v_escrow
  FROM public.escrow_records
  WHERE order_id = p_order_id
  FOR UPDATE;

  IF v_order.status IN ('paid','shipped','delivered','refund_requested','disputed')
     OR (v_escrow.id IS NOT NULL AND v_escrow.status = 'frozen')
     OR EXISTS (
       SELECT 1
       FROM public.payment_orders po
       WHERE po.business_type = 'order'
         AND po.business_id = p_order_id
         AND po.status = 'paid'
     ) THEN
    RETURN jsonb_build_object(
      'success', false,
      'code', 'REFUND_REQUIRED',
      'error', 'Paid or escrowed orders must use the refund flow',
      'status', v_order.status
    );
  END IF;

  IF v_order.status NOT IN ('pending','pending_payment') THEN
    RETURN jsonb_build_object('success', false, 'code', 'ORDER_NOT_CANCELLABLE',
      'error', 'Order status does not allow cancellation', 'status', v_order.status);
  END IF;

  UPDATE public.payment_orders
  SET status = 'closed', updated_at = NOW()
  WHERE business_type = 'order'
    AND business_id = p_order_id
    AND status = 'pending';

  IF v_order.product_id IS NOT NULL THEN
    SELECT public.release_shop_order_stock(
      p_order_id,
      v_order.product_id,
      COALESCE(v_order.quantity, 1)
    ) INTO v_stock_result;

    IF COALESCE((v_stock_result->>'success')::BOOLEAN, FALSE) IS NOT TRUE THEN
      RAISE EXCEPTION '0058 shop stock release failed for order %', p_order_id;
    END IF;
  END IF;

  UPDATE public.orders
  SET status = 'cancelled', cancelled_at = NOW(), updated_at = NOW()
  WHERE id = p_order_id;

  UPDATE public.consignments
  SET status = 'active', updated_at = NOW()
  WHERE id = v_order.consignment_id
    AND status = 'reserved';

  IF v_order.seller_id IS NOT NULL THEN
    INSERT INTO public.notifications(user_id, type, title, content, related_id)
    VALUES (
      v_order.seller_id,
      'order_cancelled',
      'Order cancelled',
      'Order ' || v_order.order_no || ' was cancelled',
      p_order_id
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'order_id', p_order_id, 'status', 'cancelled');
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_order(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(UUID) TO authenticated;

COMMENT ON FUNCTION public.cancel_order(UUID) IS
  'CR-0104-T-FIX: party-authorized cancellation using orders.consignment_id; paid/frozen orders require refund.';

COMMIT;
