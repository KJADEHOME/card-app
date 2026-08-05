-- TASK-CR-0104-Q: restore the missing marketplace order-creation RPC.
-- Reuses the reviewed 0045 listing -> pending order -> reserved listing design.
-- Payment and escrow execution remain in the existing payment RPCs.

BEGIN;

DO $$
DECLARE
  v_missing TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF to_regprocedure('public.create_marketplace_order(uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION
      '0054 expected create_marketplace_order(uuid,text) to be absent; audit existing definition instead';
  END IF;

  IF to_regclass('public.consignments') IS NULL THEN
    v_missing := array_append(v_missing, 'public.consignments');
  END IF;
  IF to_regclass('public.orders') IS NULL THEN
    v_missing := array_append(v_missing, 'public.orders');
  END IF;
  IF to_regclass('public.platform_config') IS NULL THEN
    v_missing := array_append(v_missing, 'public.platform_config');
  END IF;
  IF to_regclass('public.escrow_records') IS NULL THEN
    v_missing := array_append(v_missing, 'public.escrow_records');
  END IF;
  IF to_regprocedure('public.pay_with_balance(uuid)') IS NULL THEN
    v_missing := array_append(v_missing, 'public.pay_with_balance(uuid)');
  END IF;

  IF cardinality(v_missing) > 0 THEN
    RAISE EXCEPTION '0054 missing prerequisites: %', array_to_string(v_missing, ', ');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('orders', 'idempotency_key'),
      ('orders', 'seller_amount'),
      ('orders', 'seller_earnings'),
      ('consignments', 'quantity')
    ) AS required(table_name, column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns AS c
      WHERE c.table_schema = 'public'
        AND c.table_name = required.table_name
        AND c.column_name = required.column_name
    )
  ) THEN
    RAISE EXCEPTION '0054 required marketplace compatibility columns are missing';
  END IF;
END;
$$;

CREATE FUNCTION public.create_marketplace_order(
  p_consignment_id UUID,
  p_idempotency_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_buyer UUID := auth.uid();
  v_item public.consignments%ROWTYPE;
  v_existing public.orders%ROWTYPE;
  v_order_id UUID;
  v_order_no TEXT;
  v_total NUMERIC(12,2);
  v_rate NUMERIC := 0.03;
  v_fee NUMERIC(12,2);
  v_seller_amount NUMERIC(12,2);
BEGIN
  IF v_buyer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Authentication required');
  END IF;

  IF p_idempotency_key IS NOT NULL THEN
    SELECT *
    INTO v_existing
    FROM public.orders
    WHERE idempotency_key = p_idempotency_key
      AND buyer_id = v_buyer
    LIMIT 1;

    IF v_existing.id IS NOT NULL THEN
      RETURN jsonb_build_object(
        'success', true,
        'idempotent', true,
        'order_id', v_existing.id,
        'order_no', v_existing.order_no,
        'total_amount', v_existing.total_amount,
        'status', v_existing.status
      );
    END IF;
  END IF;

  SELECT *
  INTO v_item
  FROM public.consignments
  WHERE id = p_consignment_id
  FOR UPDATE;

  IF v_item.id IS NULL OR v_item.status <> 'active' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Listing unavailable');
  END IF;
  IF v_item.seller_id = v_buyer THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cannot buy own listing');
  END IF;
  IF v_item.asking_price <= 0 OR COALESCE(v_item.quantity, 1) <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid listing');
  END IF;

  SELECT COALESCE(value::NUMERIC, 0.03)
  INTO v_rate
  FROM public.platform_config
  WHERE key = 'platform_fee_rate';

  v_total := v_item.asking_price + COALESCE(v_item.shipping_fee, 0);
  v_fee := ROUND(v_total * COALESCE(v_rate, 0.03), 2);
  v_seller_amount := v_total - v_fee;
  v_order_no := 'CR'
    || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS')
    || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 4));

  INSERT INTO public.orders (
    order_no, buyer_id, seller_id, consignment_id,
    item_price, shipping_fee, platform_fee, total_amount,
    seller_earnings, seller_amount, currency, status, idempotency_key
  ) VALUES (
    v_order_no, v_buyer, v_item.seller_id, v_item.id,
    v_item.asking_price, COALESCE(v_item.shipping_fee, 0), v_fee, v_total,
    v_seller_amount, v_seller_amount, 'CNY', 'pending', p_idempotency_key
  )
  RETURNING id INTO v_order_id;

  UPDATE public.consignments
  SET status = 'reserved', updated_at = NOW()
  WHERE id = v_item.id;

  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'order_no', v_order_no,
    'card_name', v_item.card_name,
    'total_amount', v_total,
    'platform_fee', v_fee,
    'seller_amount', v_seller_amount,
    'status', 'pending'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_marketplace_order(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_marketplace_order(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_marketplace_order(UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.create_marketplace_order(UUID, TEXT) IS
  'CR-0104-Q: create a pending marketplace order and reserve its active consignment; payment creates escrow separately.';

COMMIT;
