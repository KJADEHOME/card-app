CREATE OR REPLACE FUNCTION admin_update_sealed_product(
  p_admin_id UUID, p_product_id UUID DEFAULT NULL,
  p_name TEXT DEFAULT NULL, p_product_type TEXT DEFAULT NULL,
  p_sku TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL,
  p_images TEXT[] DEFAULT NULL, p_thumbnail_url TEXT DEFAULT NULL,
  p_packs_per_box INTEGER DEFAULT NULL, p_cards_per_pack INTEGER DEFAULT NULL,
  p_total_cards INTEGER DEFAULT NULL, p_guaranteed_hits TEXT DEFAULT NULL,
  p_rarity_distribution JSONB DEFAULT NULL, p_cost_price NUMERIC DEFAULT NULL,
  p_listing_price NUMERIC DEFAULT NULL, p_original_price NUMERIC DEFAULT NULL,
  p_member_price NUMERIC DEFAULT NULL, p_stock_quantity INTEGER DEFAULT NULL,
  p_min_order_quantity INTEGER DEFAULT NULL, p_max_order_quantity INTEGER DEFAULT NULL,
  p_is_pre_order BOOLEAN DEFAULT NULL, p_release_date DATE DEFAULT NULL,
  p_shipping_date DATE DEFAULT NULL, p_shipping_fee NUMERIC DEFAULT NULL,
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
  UPDATE public.sealed_products SET
    name = COALESCE(p_name, public.sealed_products.name),
    product_type = COALESCE(p_product_type, public.sealed_products.product_type),
    sku = COALESCE(p_sku, public.sealed_products.sku),
    description = COALESCE(p_description, public.sealed_products.description),
    images = COALESCE(p_images, public.sealed_products.images),
    thumbnail_url = COALESCE(p_thumbnail_url, public.sealed_products.thumbnail_url),
    packs_per_box = COALESCE(p_packs_per_box, public.sealed_products.packs_per_box),
    cards_per_pack = COALESCE(p_cards_per_pack, public.sealed_products.cards_per_pack),
    total_cards = COALESCE(p_total_cards, public.sealed_products.total_cards),
    guaranteed_hits = COALESCE(p_guaranteed_hits, public.sealed_products.guaranteed_hits),
    rarity_distribution = COALESCE(p_rarity_distribution, public.sealed_products.rarity_distribution),
    cost_price = COALESCE(p_cost_price, public.sealed_products.cost_price),
    listing_price = COALESCE(p_listing_price, public.sealed_products.listing_price),
    original_price = COALESCE(p_original_price, public.sealed_products.original_price),
    member_price = COALESCE(p_member_price, public.sealed_products.member_price),
    stock_quantity = COALESCE(p_stock_quantity, public.sealed_products.stock_quantity),
    min_order_quantity = COALESCE(p_min_order_quantity, public.sealed_products.min_order_quantity),
    max_order_quantity = COALESCE(p_max_order_quantity, public.sealed_products.max_order_quantity),
    is_pre_order = COALESCE(p_is_pre_order, public.sealed_products.is_pre_order),
    release_date = COALESCE(p_release_date, public.sealed_products.release_date),
    shipping_date = COALESCE(p_shipping_date, public.sealed_products.shipping_date),
    shipping_fee = COALESCE(p_shipping_fee, public.sealed_products.shipping_fee),
    status = COALESCE(p_status, public.sealed_products.status),
    tags = COALESCE(p_tags, public.sealed_products.tags),
    updated_at = now()
  WHERE id = p_product_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'Product not found'::TEXT; RETURN;
  END IF;
  RETURN QUERY SELECT true, 'Sealed product updated'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

CREATE OR REPLACE FUNCTION create_sealed_product_order(
  p_user_id UUID, p_product_id UUID, p_quantity INTEGER DEFAULT 1,
  p_buyer_address JSONB DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, order_id UUID, order_no TEXT, total_amount NUMERIC, message TEXT)
AS $func$
DECLARE
  v_product_rec RECORD; v_order_no TEXT; v_order_id UUID;
  v_total_amount NUMERIC(10,2); v_available INTEGER;
BEGIN
  SELECT * INTO v_product_rec FROM public.sealed_products WHERE id = p_product_id;
  IF v_product_rec IS NULL THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Product not found'::TEXT; RETURN;
  END IF;
  IF v_product_rec.status NOT IN ('active', 'on_sale', 'pre_order') THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Product not available'::TEXT; RETURN;
  END IF;
  IF v_product_rec.is_pre_order THEN
    IF now() < v_product_rec.pre_order_start OR now() > v_product_rec.pre_order_end THEN
      RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Pre-order not active'::TEXT; RETURN;
    END IF;
  END IF;
  IF p_quantity < v_product_rec.min_order_quantity THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Below minimum order qty'::TEXT; RETURN;
  END IF;
  IF p_quantity > v_product_rec.max_order_quantity THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Above maximum order qty'::TEXT; RETURN;
  END IF;
  v_available := v_product_rec.stock_quantity - v_product_rec.reserved_quantity - v_product_rec.sold_quantity;
  IF v_available < p_quantity THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Insufficient stock'::TEXT; RETURN;
  END IF;
  v_total_amount := v_product_rec.listing_price * p_quantity + v_product_rec.shipping_fee;
  v_order_no := 'SP-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(extensions.gen_random_uuid()::text, 1, 8);
  INSERT INTO public.sealed_product_orders (
    order_no, user_id, sealed_product_id, quantity, unit_price, total_amount,
    shipping_fee, platform_fee, is_pre_order, estimated_ship_date,
    buyer_address, status, payment_status
  ) VALUES (
    v_order_no, p_user_id, p_product_id, p_quantity, v_product_rec.listing_price, v_total_amount,
    v_product_rec.shipping_fee, ROUND(v_total_amount * v_product_rec.platform_fee_pct / 100, 2),
    v_product_rec.is_pre_order, v_product_rec.shipping_date,
    p_buyer_address, 'pending', 'unpaid'
  ) RETURNING id, order_no INTO v_order_id, v_order_no;
  UPDATE public.sealed_products SET reserved_quantity = reserved_quantity + p_quantity, updated_at = now()
  WHERE id = p_product_id;
  RETURN QUERY SELECT true, v_order_id, v_order_no, v_total_amount, 'Order created'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

CREATE OR REPLACE FUNCTION cancel_sealed_product_order(
  p_order_id UUID, p_user_id UUID, p_reason TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT)
AS $func$
DECLARE v_order_rec RECORD;
BEGIN
  SELECT * INTO v_order_rec FROM public.sealed_product_orders WHERE id = p_order_id AND user_id = p_user_id;
  IF v_order_rec IS NULL THEN
    RETURN QUERY SELECT false, 'Order not found'::TEXT; RETURN;
  END IF;
  IF v_order_rec.status NOT IN ('pending', 'confirmed') THEN
    RETURN QUERY SELECT false, 'Cannot cancel'::TEXT; RETURN;
  END IF;
  UPDATE public.sealed_product_orders SET status = 'cancelled', cancelled_at = now(), updated_at = now()
  WHERE id = p_order_id;
  UPDATE public.sealed_products SET reserved_quantity = reserved_quantity - v_order_rec.quantity, updated_at = now()
  WHERE id = v_order_rec.sealed_product_id;
  RETURN QUERY SELECT true, 'Cancelled, stock released'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';
