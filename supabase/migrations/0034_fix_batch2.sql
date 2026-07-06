CREATE OR REPLACE FUNCTION admin_confirm_sealed_order(
  p_admin_id UUID, p_order_id UUID DEFAULT NULL,
  p_tracking_no TEXT DEFAULT NULL, p_shipping_carrier TEXT DEFAULT NULL,
  p_action TEXT DEFAULT 'confirm'
)
RETURNS TABLE(success BOOLEAN, message TEXT)
AS $func$
DECLARE v_admin_status TEXT; v_order_rec RECORD;
BEGIN
  SELECT status INTO v_admin_status FROM public.admins WHERE id = p_admin_id;
  IF v_admin_status IS NULL OR v_admin_status != 'active' THEN
    RETURN QUERY SELECT false, 'Admin not authorized'::TEXT; RETURN;
  END IF;
  SELECT * INTO v_order_rec FROM public.sealed_product_orders WHERE id = p_order_id;
  IF v_order_rec IS NULL THEN
    RETURN QUERY SELECT false, 'Order not found'::TEXT; RETURN;
  END IF;
  CASE p_action
    WHEN 'confirm' THEN
      IF v_order_rec.status != 'pending' THEN RETURN QUERY SELECT false, 'Must be pending'::TEXT; RETURN; END IF;
      UPDATE public.sealed_product_orders SET status = 'confirmed', updated_at = now() WHERE id = p_order_id;
    WHEN 'ship' THEN
      IF v_order_rec.status NOT IN ('confirmed', 'paid') THEN RETURN QUERY SELECT false, 'Must be confirmed/paid'::TEXT; RETURN; END IF;
      UPDATE public.sealed_product_orders SET status = 'shipping',
        tracking_no = COALESCE(p_tracking_no, public.sealed_product_orders.tracking_no),
        shipping_carrier = COALESCE(p_shipping_carrier, public.sealed_product_orders.shipping_carrier),
        shipped_at = now(), updated_at = now() WHERE id = p_order_id;
      UPDATE public.sealed_products SET sold_quantity = sold_quantity + v_order_rec.quantity,
        reserved_quantity = reserved_quantity - v_order_rec.quantity, updated_at = now()
      WHERE id = v_order_rec.sealed_product_id;
    WHEN 'deliver' THEN
      IF v_order_rec.status != 'shipping' THEN RETURN QUERY SELECT false, 'Must be shipping'::TEXT; RETURN; END IF;
      UPDATE public.sealed_product_orders SET status = 'delivered', delivered_at = now(), updated_at = now() WHERE id = p_order_id;
    ELSE RETURN QUERY SELECT false, 'Invalid action'::TEXT; RETURN;
  END CASE;
  RETURN QUERY SELECT true, 'Order ' || p_action || 'ed'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

CREATE OR REPLACE FUNCTION admin_create_merchandise(
  p_admin_id UUID, p_name TEXT DEFAULT 'New Merch',
  p_merch_type TEXT DEFAULT 'accessories', p_sku TEXT DEFAULT 'SKU-MC-TEMP',
  p_listing_price NUMERIC DEFAULT 50.00,
  p_name_en TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL,
  p_images TEXT[] DEFAULT NULL, p_thumbnail_url TEXT DEFAULT NULL,
  p_material TEXT DEFAULT NULL, p_color TEXT DEFAULT NULL, p_size TEXT DEFAULT NULL,
  p_weight_grams INTEGER DEFAULT NULL, p_cost_price NUMERIC DEFAULT 0,
  p_original_price NUMERIC DEFAULT NULL, p_member_price NUMERIC DEFAULT NULL,
  p_stock_quantity INTEGER DEFAULT 0, p_shipping_fee NUMERIC DEFAULT 0,
  p_platform_fee_pct NUMERIC DEFAULT 0, p_tags TEXT[] DEFAULT NULL,
  p_brand TEXT DEFAULT NULL, p_related_card_series TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, merchandise_id UUID, sku TEXT, message TEXT)
AS $func$
DECLARE v_admin_status TEXT; v_merch_id UUID;
BEGIN
  SELECT status INTO v_admin_status FROM public.admins WHERE id = p_admin_id;
  IF v_admin_status IS NULL OR v_admin_status != 'active' THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 'Admin not authorized'::TEXT; RETURN;
  END IF;
  INSERT INTO public.merchandise (
    admin_id, name, name_en, merch_type, sku, description, images, thumbnail_url,
    material, color, size, weight_grams,
    cost_price, listing_price, original_price, member_price,
    stock_quantity, shipping_fee, platform_fee_pct, tags, brand, related_card_series, status
  ) VALUES (
    p_admin_id, p_name, p_name_en, p_merch_type, p_sku, p_description, p_images, p_thumbnail_url,
    p_material, p_color, p_size, p_weight_grams,
    p_cost_price, p_listing_price, p_original_price, p_member_price,
    p_stock_quantity, p_shipping_fee, p_platform_fee_pct, p_tags, p_brand, p_related_card_series,
    'draft'
  ) RETURNING id, sku INTO v_merch_id, p_sku;
  INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
  VALUES (p_admin_id, 'create_merchandise', 'merchandise', v_merch_id,
    jsonb_build_object('name', p_name, 'sku', p_sku, 'merch_type', p_merch_type));
  RETURN QUERY SELECT true, v_merch_id, p_sku, 'Merchandise created'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

CREATE OR REPLACE FUNCTION admin_update_merchandise(
  p_admin_id UUID, p_merchandise_id UUID DEFAULT NULL,
  p_name TEXT DEFAULT NULL, p_merch_type TEXT DEFAULT NULL,
  p_sku TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL,
  p_images TEXT[] DEFAULT NULL, p_thumbnail_url TEXT DEFAULT NULL,
  p_material TEXT DEFAULT NULL, p_color TEXT DEFAULT NULL, p_size TEXT DEFAULT NULL,
  p_cost_price NUMERIC DEFAULT NULL, p_listing_price NUMERIC DEFAULT NULL,
  p_original_price NUMERIC DEFAULT NULL, p_member_price NUMERIC DEFAULT NULL,
  p_stock_quantity INTEGER DEFAULT NULL, p_shipping_fee NUMERIC DEFAULT NULL,
  p_status TEXT DEFAULT NULL, p_tags TEXT[] DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT)
AS $func$
DECLARE v_admin_status TEXT;
BEGIN
  SELECT status INTO v_admin_status FROM public.admins WHERE id = p_admin_id;
  IF v_admin_status IS NULL OR v_admin_status != 'active' THEN
    RETURN QUERY SELECT false, 'Admin not authorized'::TEXT; RETURN;
  END IF;
  UPDATE public.merchandise SET
    name = COALESCE(p_name, public.merchandise.name),
    merch_type = COALESCE(p_merch_type, public.merchandise.merch_type),
    sku = COALESCE(p_sku, public.merchandise.sku),
    description = COALESCE(p_description, public.merchandise.description),
    images = COALESCE(p_images, public.merchandise.images),
    thumbnail_url = COALESCE(p_thumbnail_url, public.merchandise.thumbnail_url),
    material = COALESCE(p_material, public.merchandise.material),
    color = COALESCE(p_color, public.merchandise.color),
    size = COALESCE(p_size, public.merchandise.size),
    cost_price = COALESCE(p_cost_price, public.merchandise.cost_price),
    listing_price = COALESCE(p_listing_price, public.merchandise.listing_price),
    original_price = COALESCE(p_original_price, public.merchandise.original_price),
    member_price = COALESCE(p_member_price, public.merchandise.member_price),
    stock_quantity = COALESCE(p_stock_quantity, public.merchandise.stock_quantity),
    shipping_fee = COALESCE(p_shipping_fee, public.merchandise.shipping_fee),
    status = COALESCE(p_status, public.merchandise.status),
    tags = COALESCE(p_tags, public.merchandise.tags),
    updated_at = now()
  WHERE id = p_merchandise_id;
  IF NOT FOUND THEN RETURN QUERY SELECT false, 'Merchandise not found'::TEXT; RETURN; END IF;
  RETURN QUERY SELECT true, 'Merchandise updated'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

CREATE OR REPLACE FUNCTION create_merchandise_order(
  p_user_id UUID, p_merchandise_id UUID, p_quantity INTEGER DEFAULT 1,
  p_selected_color TEXT DEFAULT NULL, p_selected_size TEXT DEFAULT NULL,
  p_buyer_address JSONB DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, order_id UUID, order_no TEXT, total_amount NUMERIC, message TEXT)
AS $func$
DECLARE
  v_merch_rec RECORD; v_order_no TEXT; v_order_id UUID;
  v_total_amount NUMERIC(10,2); v_available INTEGER;
BEGIN
  SELECT * INTO v_merch_rec FROM public.merchandise WHERE id = p_merchandise_id;
  IF v_merch_rec IS NULL THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Merchandise not found'::TEXT; RETURN;
  END IF;
  IF v_merch_rec.status NOT IN ('active', 'on_sale') THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Not available'::TEXT; RETURN;
  END IF;
  v_available := v_merch_rec.stock_quantity - v_merch_rec.reserved_quantity - v_merch_rec.sold_quantity;
  IF v_available < p_quantity THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Insufficient stock'::TEXT; RETURN;
  END IF;
  v_total_amount := v_merch_rec.listing_price * p_quantity + v_merch_rec.shipping_fee;
  v_order_no := 'MC-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(extensions.gen_random_uuid()::text, 1, 8);
  INSERT INTO public.merchandise_orders (
    order_no, user_id, merchandise_id, quantity, unit_price, total_amount,
    shipping_fee, platform_fee, selected_color, selected_size, buyer_address,
    status, payment_status
  ) VALUES (
    v_order_no, p_user_id, p_merchandise_id, p_quantity, v_merch_rec.listing_price, v_total_amount,
    v_merch_rec.shipping_fee, ROUND(v_total_amount * v_merch_rec.platform_fee_pct / 100, 2),
    p_selected_color, p_selected_size, p_buyer_address, 'pending', 'unpaid'
  ) RETURNING id, order_no INTO v_order_id, v_order_no;
  UPDATE public.merchandise SET reserved_quantity = reserved_quantity + p_quantity, updated_at = now()
  WHERE id = p_merchandise_id;
  RETURN QUERY SELECT true, v_order_id, v_order_no, v_total_amount, 'Merchandise order created'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';
