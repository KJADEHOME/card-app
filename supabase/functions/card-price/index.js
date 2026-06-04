"use strict";

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
};

// CNY/USD exchange rate (approximate, updated periodically)
const USD_TO_CNY = 7.25;

/**
 * Format price for display
 */
function fmtPrice(val, currency) {
  if (val == null || val === 0) return null;
  const symbol = currency === "CNY" ? "¥" : currency === "EUR" ? "€" : "$";
  return `${symbol}${val.toFixed(2)}`;
}

/**
 * Search TCGdex for Pokemon cards by name
 */
async function searchTcgdex(name) {
  const url = `https://api.tcgdex.net/v2/en/cards?name=${encodeURIComponent(name)}`;
  const resp = await fetch(url);
  if (!resp.ok) return [];
  const data = await resp.json();
  return data || [];
}

/**
 * Get card detail with pricing from TCGdex
 */
async function getCardPricing(cardId) {
  const url = `https://api.tcgdex.net/v2/en/cards/${encodeURIComponent(cardId)}`;
  const resp = await fetch(url);
  if (!resp.ok) return null;
  return await resp.json();
}

/**
 * Pick the best match from search results
 * Strategy: prefer results with exact name match, then shortest ID (usually most iconic version)
 */
function pickBestMatch(results, targetName) {
  if (!results || results.length === 0) return null;

  const lower = targetName.toLowerCase().trim();

  // First: try exact name match
  const exact = results.filter(c => (c.name || "").toLowerCase().trim() === lower);
  if (exact.length > 0) return exact[0];

  // Second: try name starts with
  const starts = results.filter(c => (c.name || "").toLowerCase().trim().startsWith(lower));
  if (starts.length > 0) return starts[0];

  // Third: just return first result
  return results[0];
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { name, series, market } = body;

    if (!name) {
      return new Response(
        JSON.stringify({ success: false, error: "Card name is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const marketRegion = market || "US"; // default: US market
    const cardSeries = (series || "Unknown").toLowerCase();

    let pricing = null;
    let source = null;
    let marketNote = null;

    // === Pokemon: TCGdex (free, no API key) ===
    if (cardSeries.includes("pokemon") || cardSeries.includes("宝可梦") || cardSeries.includes("pokémon")) {
      console.log(`[card-price] Pokemon: searching "${name}" via TCGdex`);

      const searchResults = await searchTcgdex(name);
      console.log(`[card-price] TCGdex search returned ${searchResults.length} results`);

      if (searchResults.length > 0) {
        // Try multiple candidates until we find one with pricing data
        const candidates = searchResults.slice(0, 8); // try first 8 matches
        let bestDetail = null;
        let bestCard = null;

        for (const card of candidates) {
          if (!card.id) continue;
          const detail = await getCardPricing(card.id);
          if (detail && detail.pricing && (detail.pricing.tcgplayer || detail.pricing.cardmarket)) {
            bestDetail = detail;
            bestCard = card;
            console.log(`[card-price] Found pricing for ${card.id}: ${detail.name}`);
            break;
          }
        }

        // Fallback: use first match even without pricing
        if (!bestDetail && candidates.length > 0) {
          bestCard = candidates[0];
          bestDetail = await getCardPricing(bestCard.id);
          console.log(`[card-price] Fallback: using ${bestCard.id} (no pricing available)`);
        }

        if (bestDetail && bestCard) {
          const p = bestDetail.pricing;

          if (p && (p.tcgplayer || p.cardmarket)) {
            source = "TCGdex (TCGPlayer + Cardmarket)";
          }

          const usd = (p && p.tcgplayer) || null;
          const eur = (p && p.cardmarket) || null;

          // Build pricing response
          pricing = {
            cardId: bestCard.id,
            matchedName: bestDetail.name || bestCard.name,
            image: bestDetail.image ? `https://assets.tcgdex.net/en/${bestCard.id}/${bestDetail.image}` : null,
          };

          // TCGPlayer can have multiple variant keys: normal, holofoil, reverse, reverse-holofoil, 1stEdition
          function getTcgPrice(usdData) {
            if (!usdData) return null;
            // Try in priority order: normal > holofoil > reverse > reverse-holofoil > 1stEdition > unlimited
            const keys = ["normal", "holofoil", "reverse", "reverse-holofoil", "1stEdition", "unlimited"];
            for (const k of keys) {
              if (usdData[k] && usdData[k].marketPrice != null) return usdData[k];
            }
            // If none found, return first available
            for (const k of keys) {
              if (usdData[k]) return usdData[k];
            }
            return null;
          }

          const usdPrice = getTcgPrice(usd);
          const hasPrice = usdPrice || eur;

          if (hasPrice) {
            if (marketRegion === "US" || marketRegion === "USD") {
              pricing.market = "US";
              pricing.currency = "USD";
              if (usdPrice) {
                pricing.low = usdPrice.lowPrice;
                pricing.mid = usdPrice.midPrice;
                pricing.high = usdPrice.highPrice;
                pricing.market_price = usdPrice.marketPrice;
                pricing.variant = usdPrice === usd.normal ? "normal" : usdPrice === usd.holofoil ? "holofoil" : usdPrice === usd.reverse ? "reverse" : "special";
              } else if (eur) {
                // No TCGPlayer data, use Cardmarket as fallback (EUR→USD approx)
                const eurTrend = eur.trend || eur.avg30 || 0;
                pricing.market_price = Math.round(eurTrend * 1.10 * 100) / 100; // EUR*1.10≈USD
                pricing.estimated = true;
              }
              if (eur) {
                pricing.eur_market = eur.trend || eur.avg30;
              }
            } else {
              // CN market: show USD converted to CNY
              pricing.market = "CN";
              pricing.currency = "CNY";
              if (usdPrice) {
                pricing.low = usdPrice.lowPrice ? Math.round(usdPrice.lowPrice * USD_TO_CNY * 100) / 100 : null;
                pricing.mid = usdPrice.midPrice ? Math.round(usdPrice.midPrice * USD_TO_CNY * 100) / 100 : null;
                pricing.high = usdPrice.highPrice ? Math.round(usdPrice.highPrice * USD_TO_CNY * 100) / 100 : null;
                pricing.market_price = usdPrice.marketPrice ? Math.round(usdPrice.marketPrice * USD_TO_CNY * 100) / 100 : null;
              } else if (eur) {
                const eurTrend = eur.trend || eur.avg30 || 0;
                pricing.market_price = Math.round(eurTrend * 7.68 * 100) / 100; // EUR→CNY
                pricing.estimated = true;
              }
              if (eur) {
                pricing.eur_ref = eur.trend || eur.avg30;
              }
              marketNote = `基于TCGPlayer美元价 × ${USD_TO_CNY}汇率换算，仅供参考`;
            }
          }

          if (source) pricing.source = source;
          if (marketNote) pricing.note = marketNote;
        }
      }
    }

    // === Yu-Gi-Oh / Magic: not yet supported ===
    if (!pricing) {
      const yuGiOh = cardSeries.includes("yugioh") || cardSeries.includes("游戏王") || cardSeries.includes("yu-gi-oh");
      const mtg = cardSeries.includes("magic") || cardSeries.includes("万智牌") || cardSeries.includes("mtg");

      if (yuGiOh || mtg) {
        const gameName = yuGiOh ? "游戏王/Yu-Gi-Oh" : "万智牌/Magic: The Gathering";
        return new Response(
          JSON.stringify({
            success: true,
            data: {
              name: name,
              series: series,
              pricing: null,
              message: `${gameName} 价格查询即将支持`,
              message_en: `${gameName} pricing coming soon`,
            }
          }),
          { headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    if (!pricing) {
      return new Response(
        JSON.stringify({
          success: true,
          data: {
            name: name,
            series: series,
            pricing: null,
            message: "未找到该卡牌的价格数据",
            message_en: "No pricing data found for this card",
          }
        }),
        { headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        data: {
          name: name,
          series: series,
          ...pricing,
        }
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (err) {
    console.error("[card-price] Error:", err.message);
    return new Response(
      JSON.stringify({ success: false, error: err.message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
