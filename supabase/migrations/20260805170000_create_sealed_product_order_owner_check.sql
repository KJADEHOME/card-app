-- ============================================================
-- CR-0110-A: SF-1 owner-check for create_sealed_product_order()
-- ============================================================
-- 背景: CR0107 04F-U smoke test (SF-1, HIGH) 发现
--   create_sealed_product_order() 为 SECURITY DEFINER, 直接使用传入的
--   p_user_id 建单, 未校验调用者身份。攻击者可持自己的 JWT 传入他人
--   p_user_id 为他人下单 (TC-3.1 security gap 已复现)。
--
-- 修复: 在函数体最前加入 owner-check —— 仅当 p_user_id = auth.uid() 时
--   放行, 否则 RAISE 42501 (insufficient_privilege), 与 RLS 违规码一致。
--
-- 设计要点:
--   1. 使用普通 `!=` 运算符 (NOT `IS DISTINCT FROM`):
--      - 客户端持本人 JWT 调用: auth.uid() = 本人 id, p_user_id = 本人 id → 不触发 ✅
--      - 客户端伪造他人 p_user_id: auth.uid() = 本人 id, p_user_id = 他人 id → 触发 42501 ✅
--      - 以 service_role key 调用 (Edge Function/后台): auth.uid() 为 NULL,
--        `p_user_id != NULL` 求值 NULL (非 TRUE) → 不触发, 保留合法后台/管理员调用 ✅
--   2. auth.uid() 在 SECURITY DEFINER 内仍反映请求 JWT 的 sub (request.jwt.claims
--      不被 SECURITY DEFINER 清空), 且以 auth. 完全限定, 在 search_path='' 下可解析。
--   3. 仅新增授权校验, 不改变原订单逻辑 / 库存锁定 / preorder 逻辑 / payment 状态。
-- ============================================================

CREATE OR REPLACE FUNCTION create_sealed_product_order(
  p_user_id UUID, p_product_id UUID, p_quantity INTEGER DEFAULT 1,
  p_buyer_address JSONB DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, order_id UUID, order_no TEXT, total_amount NUMERIC, message TEXT)
AS $func$
#variable_conflict use_column
DECLARE
  v_product_rec RECORD; v_order_no_val TEXT; v_order_id UUID;
  v_total_amount NUMERIC(10,2); v_available INTEGER;
BEGIN
  -- [CR-0110-A / SF-1] owner-check: 调用者只能为自己下单
  IF p_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Cannot create an order on behalf of another user'
      USING ERRCODE = '42501';
  END IF;

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
  v_order_no_val := 'SP-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(extensions.gen_random_uuid()::text, 1, 8);
  INSERT INTO public.sealed_product_orders (
    order_no, user_id, sealed_product_id, quantity, unit_price, total_amount,
    shipping_fee, platform_fee, is_pre_order, estimated_ship_date,
    buyer_address, status, payment_status
  ) VALUES (
    v_order_no_val, p_user_id, p_product_id, p_quantity, v_product_rec.listing_price, v_total_amount,
    v_product_rec.shipping_fee, ROUND(v_total_amount * v_product_rec.platform_fee_pct / 100, 2),
    v_product_rec.is_pre_order, v_product_rec.shipping_date,
    p_buyer_address, 'pending', 'unpaid'
  ) RETURNING id, order_no INTO v_order_id, v_order_no_val;
  UPDATE public.sealed_products SET reserved_quantity = reserved_quantity + p_quantity, updated_at = now()
  WHERE id = p_product_id;
  RETURN QUERY SELECT true, v_order_id, v_order_no_val, v_total_amount, 'Order created'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION create_sealed_product_order(UUID, UUID, INTEGER, JSONB) IS '用户下单购买一级市场商品(盲盒) — 锁定价格, 冻结库存 [CR-0110-A] 强制 p_user_id = auth.uid() (SF-1 修复)';
