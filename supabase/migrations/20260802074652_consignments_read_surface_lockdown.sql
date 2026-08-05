-- Limit public clients to marketplace-safe consignment columns.
CREATE OR REPLACE VIEW public.secondary_market_list
WITH (security_invoker = true)
AS
SELECT
  c.id AS consignment_id, c.seller_id, NULL::text AS seller_name,
  c.card_name, c.card_name_en, c.card_image, c.series, c.rarity,
  c.card_category, c.condition, c.description, c.asking_price, c.quantity,
  c.shipping_fee, NULL::numeric(5,2) AS platform_fee_pct, c.status, c.tags,
  c.view_count, c.wishlist_count, c.listed_at,
  cm.final_price AS mark_price, cm.mark_price AS latest_mark_price,
  cm.price_source, cm.market_state, cm.activity_score,
  CASE WHEN cm.mark_price > 0 AND c.asking_price > 0
    THEN round(((c.asking_price - cm.mark_price) / cm.mark_price) * 100, 2)
    ELSE NULL::numeric END AS price_vs_mark_pct,
  CASE c.is_platform_sale WHEN true THEN 'platform' ELSE 'user' END AS listing_source
FROM public.consignments AS c
LEFT JOIN public.card_market AS cm
  ON cm.card_name = c.card_name AND cm.series = c.series
 AND cm.rarity = c.rarity
 AND cm.market = coalesce(c.card_category, 'pokemon')
WHERE c.status = 'active'
ORDER BY c.is_platform_sale DESC, c.created_at DESC;

REVOKE SELECT, REFERENCES, TRIGGER ON public.consignments FROM anon;
REVOKE SELECT ON public.consignments FROM authenticated;

GRANT SELECT (
  id, seller_id, card_name, card_name_en, card_image, series, rarity,
  card_category, condition, asking_price, currency, shipping_fee, status,
  description, tags, view_count, created_at, updated_at, collection_id,
  quantity, is_platform_sale, wishlist_count, listed_at, sold_at, expires_at,
  market_tier
) ON public.consignments TO anon, authenticated;

COMMENT ON TABLE public.consignments IS
  'Marketplace listings. Public clients have column-limited reads; settlement and fulfillment columns remain server-only.';
