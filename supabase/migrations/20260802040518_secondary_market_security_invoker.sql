-- Remove the public SECURITY DEFINER view while preserving the marketplace API
-- column contract. seller_name is currently unused by the frontend; returning
-- NULL avoids granting broad access to sensitive profile rows.

CREATE OR REPLACE VIEW public.secondary_market_list
WITH (security_invoker = true)
AS
SELECT
  c.id AS consignment_id,
  c.seller_id,
  NULL::text AS seller_name,
  c.card_name,
  c.card_name_en,
  c.card_image,
  c.series,
  c.rarity,
  c.card_category,
  c.condition,
  c.description,
  c.asking_price,
  c.quantity,
  c.shipping_fee,
  c.platform_fee_pct,
  c.status,
  c.tags,
  c.view_count,
  c.wishlist_count,
  c.listed_at,
  cm.final_price AS mark_price,
  cm.mark_price AS latest_mark_price,
  cm.price_source,
  cm.market_state,
  cm.activity_score,
  CASE
    WHEN cm.mark_price > 0 AND c.asking_price > 0
      THEN round(((c.asking_price - cm.mark_price) / cm.mark_price) * 100, 2)
    ELSE NULL::numeric
  END AS price_vs_mark_pct,
  CASE c.is_platform_sale WHEN true THEN 'platform' ELSE 'user' END AS listing_source
FROM public.consignments AS c
LEFT JOIN public.card_market AS cm
  ON cm.card_name = c.card_name
 AND cm.series = c.series
 AND cm.rarity = c.rarity
 AND cm.market = coalesce(c.card_category, 'pokemon')
WHERE c.status = 'active'
ORDER BY c.is_platform_sale DESC, c.created_at DESC;

REVOKE ALL ON public.secondary_market_list FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.secondary_market_list TO anon, authenticated, service_role;

GRANT SELECT (
  card_name, series, rarity, market, final_price, mark_price,
  price_source, market_state, activity_score
) ON public.card_market TO anon, authenticated;

COMMENT ON VIEW public.secondary_market_list IS
  'Read-only RLS-respecting secondary-market projection. seller_name is intentionally redacted.';
