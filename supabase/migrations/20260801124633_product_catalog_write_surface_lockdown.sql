-- CardRealm Beta P0: platform catalog and price state are internal-write-only.
-- Authenticated owners retain the direct consignment CRUD used by sell.html.

DROP POLICY IF EXISTS "Admin can insert card market" ON public.card_market;
DROP POLICY IF EXISTS "Admin can update card market" ON public.card_market;
DROP POLICY IF EXISTS "Anyone can read card market" ON public.card_market;
CREATE POLICY card_market_read_public ON public.card_market
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS sealed_products_write_service ON public.sealed_products;
DROP POLICY IF EXISTS platform_cards_write_service ON public.platform_cards;
DROP POLICY IF EXISTS merchandise_write_service ON public.merchandise;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE
  public.card_market, public.sealed_products, public.platform_cards, public.merchandise
FROM anon, authenticated;

REVOKE SELECT ON TABLE
  public.card_market, public.sealed_products, public.platform_cards, public.merchandise
FROM anon, authenticated;

GRANT SELECT (
  id, card_name, series, rarity, market, final_price, mark_price,
  activity_score, market_state, price_explanation, price_reason_tags,
  trade_count_24h, volatility_24h, last_explanation_update, price_source, source_type
) ON public.card_market TO anon, authenticated;

GRANT SELECT (
  id, name, name_en, set_name, card_image_url, thumbnail_url, description,
  card_category, rarity, condition, listing_price, mark_price, stock_quantity,
  reserved_quantity, sold_quantity, available_quantity, status, shipping_fee,
  platform_fee_pct, created_at, card_market_id
) ON public.platform_cards TO anon, authenticated;

GRANT SELECT (
  id, name, name_en, merch_type, brand, sku, listing_price, original_price,
  member_price, thumbnail_url, images, description, material, color, size,
  stock_quantity, available_quantity, shipping_fee, status, tags, view_count,
  related_card_series, created_at, sort_order
) ON public.merchandise TO anon, authenticated;

ALTER VIEW public.hot_cards_feed SET (security_invoker = true);
ALTER VIEW public.market_state_overview SET (security_invoker = true);
ALTER VIEW public.merchandise_store SET (security_invoker = true);
ALTER VIEW public.platform_store_list SET (security_invoker = true);
ALTER VIEW public.v_mark_price_diagnostic SET (security_invoker = true);
ALTER VIEW public.primary_market_store SET (security_invoker = true);
ALTER VIEW public.three_tier_product_catalog SET (security_invoker = true);
REVOKE SELECT ON TABLE
  public.v_mark_price_diagnostic, public.primary_market_store, public.three_tier_product_catalog
FROM anon, authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.consignments FROM anon;
REVOKE TRUNCATE ON public.consignments FROM authenticated;
DROP POLICY IF EXISTS "Sellers manage own consignments" ON public.consignments;
CREATE POLICY consignments_owner_write ON public.consignments
  FOR ALL TO authenticated
  USING ((SELECT auth.uid()) = seller_id)
  WITH CHECK ((SELECT auth.uid()) = seller_id);

COMMENT ON VIEW public.secondary_market_list IS
  'Intentional public storefront projection. Remains security-definer because profiles usernames are not directly public; output is limited to active listing fields.';
