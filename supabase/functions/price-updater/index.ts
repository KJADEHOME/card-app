// price-updater Edge Function v5 — SH-005 Security Hardening
// Fail closed on missing secrets. Caller authenticates with PRICE_UPDATER_SECRET.
// Internal RPC calls use SUPABASE_SERVICE_ROLE_KEY (never exposed to caller).
//
// Supported actions:
//   fluctuate          — full pipeline: price fluctuation → sync → card_market → portfolio → snapshots
//   sync               — sync user asset prices only
//   seed               — seed card_prices from price_history
//   market_seed        — seed card_market from card_prices
//   portfolio_sync     — sync user_collections → portfolio_items
//   portfolio_refresh  — refresh all user_portfolio
//   snapshot           — generate asset snapshots only
//   price_snapshot     — daily price snapshot card_market.final_price → price_history
//   refresh_mark_prices — batch refresh all mark_price (triggers recompute)
"use strict";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Price-Updater-Secret",
};

function jsonResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

/**
 * Validate that all required server-side environment variables are present.
 * Returns { ok: true } or { ok: false, missing: string[] }.
 */
// Required env vars: SUPABASE_URL (built-in), SUPABASE_SERVICE_ROLE_KEY (built-in),
// PRICE_UPDATER_SECRET (custom — set via Dashboard/Management API).
function validateServerConfig() {
  const required = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "PRICE_UPDATER_SECRET"];
  const missing = required.filter((k) => {
    const v = Deno.env.get(k);
    return !v || v.trim() === "";
  });
  if (missing.length > 0) {
    return { ok: false, missing };
  }
  return { ok: true };
}

/**
 * Extract the caller-provided secret from request headers.
 * Accepts either:
 *   Authorization: Bearer <PRICE_UPDATER_SECRET>
 *   X-Price-Updater-Secret: <PRICE_UPDATER_SECRET>
 */
function extractCallerSecret(req) {
  const authHeader = req.headers.get("authorization") || "";
  const bearerMatch = authHeader.match(/^Bearer\s+(.+)$/i);
  if (bearerMatch) return bearerMatch[1].trim();

  const xHeader = req.headers.get("x-price-updater-secret") || "";
  if (xHeader) return xHeader.trim();

  return "";
}

/**
 * Make an authenticated RPC call to the Supabase REST API using the
 * server-side service role key. Never uses the caller's credentials.
 */
async function rpcCall(projectUrl, serviceRoleKey, fnName, body) {
  const res = await fetch(`${projectUrl}/rest/v1/rpc/${fnName}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": serviceRoleKey,
      "Authorization": `Bearer ${serviceRoleKey}`,
    },
    body: JSON.stringify(body || {}),
  });
  return res;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ success: false, error: "Method not allowed" }, 405);
  }

  // ── 1. Server config validation (fail closed) ──────────────────
  const configCheck = validateServerConfig();
  if (!configCheck.ok) {
    console.error("[price-updater] Missing server env vars:", configCheck.missing.join(", "));
    return jsonResponse(
      { success: false, error: "Server configuration error" },
      500
    );
  }

  const PROJECT_URL = Deno.env.get("SUPABASE_URL");
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const PRICE_UPDATER_SECRET = Deno.env.get("PRICE_UPDATER_SECRET");

  // ── 2. Caller authentication ───────────────────────────────────
  const callerSecret = extractCallerSecret(req);

  if (!callerSecret) {
    return jsonResponse({ success: false, error: "unauthorized" }, 401);
  }

  if (callerSecret !== PRICE_UPDATER_SECRET) {
    return jsonResponse({ success: false, error: "unauthorized" }, 401);
  }

  // ── 3. Process action ──────────────────────────────────────────
  try {
    const body = await req.json();
    const action = body.action || "fluctuate";
    const market = body.market || "CN";

    switch (action) {
      case "fluctuate": {
        const maxChange = body.max_change_pct || 8;
        const minChange = body.min_change_pct || 1;

        const fluctuateRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "simulate_market_fluctuation", {
          p_market: market,
          p_max_change_pct: maxChange,
          p_min_change_pct: minChange,
        });

        if (!fluctuateRes.ok) {
          const err = await fluctuateRes.text();
          return jsonResponse({ success: false, error: "fluctuation RPC failed: " + err }, 500);
        }

        const fluctuateData = await fluctuateRes.json();

        // sync user asset prices
        const syncRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "sync_user_collections_prices", { p_user_id: null });
        let synced = 0;
        if (syncRes.ok) {
          const syncData = await syncRes.json();
          synced = syncData[0]?.cards_synced || 0;
        }

        // asset snapshots
        const snapRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "take_asset_snapshot", {});
        let snapshots = 0;
        if (snapRes.ok) {
          const snapData = await snapRes.json();
          snapshots = snapData[0]?.snapshots_taken || 0;
        }

        // seed card_market
        const marketSeedRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "seed_card_market", { p_market: market });
        let marketSeeded = 0;
        if (marketSeedRes.ok) {
          const msData = await marketSeedRes.json();
          marketSeeded = msData[0]?.cards_seeded || 0;
        }

        // refresh portfolios
        const portfolioRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "refresh_all_portfolios", {});
        let portfoliosRefreshed = 0;
        if (portfolioRes.ok) {
          const pfData = await portfolioRes.json();
          portfoliosRefreshed = pfData[0]?.users_refreshed || 0;
        }

        // daily price snapshot
        const priceSnapRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "take_daily_price_snapshot", { p_market: market });
        let priceSnapshots = 0;
        if (priceSnapRes.ok) {
          const psData = await priceSnapRes.json();
          priceSnapshots = psData[0]?.cards_snapshotted || 0;
        }

        return jsonResponse({
          success: true,
          data: {
            action: "fluctuate",
            market,
            ...fluctuateData[0],
            cards_synced: synced,
            snapshots_taken: snapshots,
            market_cards_seeded: marketSeeded,
            portfolios_refreshed: portfoliosRefreshed,
            price_snapshots: priceSnapshots,
          },
        });
      }

      case "sync": {
        const syncRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "sync_user_collections_prices", { p_user_id: null });
        if (!syncRes.ok) {
          return jsonResponse({ success: false, error: "sync RPC failed" }, 500);
        }
        const data = await syncRes.json();
        return jsonResponse({ success: true, data: { action: "sync", ...data[0] } });
      }

      case "seed": {
        const seedRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "seed_card_prices_from_history", { p_market: market });
        if (!seedRes.ok) {
          return jsonResponse({ success: false, error: "seed RPC failed" }, 500);
        }
        const data = await seedRes.json();
        return jsonResponse({ success: true, data: { action: "seed", ...data[0] } });
      }

      case "snapshot": {
        const snapRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "take_asset_snapshot", {});
        if (!snapRes.ok) {
          return jsonResponse({ success: false, error: "snapshot RPC failed" }, 500);
        }
        const data = await snapRes.json();
        return jsonResponse({ success: true, data: { action: "snapshot", ...data[0] } });
      }

      // ===== Phase 7 actions =====

      case "market_seed": {
        const seedRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "seed_card_market", { p_market: market });
        if (!seedRes.ok) {
          const err = await seedRes.text();
          return jsonResponse({ success: false, error: "market_seed RPC failed: " + err }, 500);
        }
        const data = await seedRes.json();
        return jsonResponse({ success: true, data: { action: "market_seed", ...data[0] } });
      }

      case "portfolio_sync": {
        const syncRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "sync_collections_to_portfolio", { p_user_id: null });
        if (!syncRes.ok) {
          const err = await syncRes.text();
          return jsonResponse({ success: false, error: "portfolio_sync RPC failed: " + err }, 500);
        }
        const data = await syncRes.json();
        return jsonResponse({ success: true, data: { action: "portfolio_sync", ...data[0] } });
      }

      case "portfolio_refresh": {
        const refreshRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "refresh_all_portfolios", {});
        if (!refreshRes.ok) {
          const err = await refreshRes.text();
          return jsonResponse({ success: false, error: "portfolio_refresh RPC failed: " + err }, 500);
        }
        const data = await refreshRes.json();
        return jsonResponse({ success: true, data: { action: "portfolio_refresh", ...data[0] } });
      }

      // ===== Phase 7.5 action =====

      case "price_snapshot": {
        const snapRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "take_daily_price_snapshot", { p_market: market });
        if (!snapRes.ok) {
          const err = await snapRes.text();
          return jsonResponse({ success: false, error: "price_snapshot RPC failed: " + err }, 500);
        }
        const data = await snapRes.json();
        return jsonResponse({ success: true, data: { action: "price_snapshot", ...data[0] } });
      }

      // ===== Phase 8 action =====

      case "refresh_mark_prices": {
        const refreshRes = await rpcCall(PROJECT_URL, SERVICE_ROLE_KEY, "refresh_all_mark_prices", { p_market: market });
        if (!refreshRes.ok) {
          const err = await refreshRes.text();
          return jsonResponse({ success: false, error: "refresh_mark_prices RPC failed: " + err }, 500);
        }
        const data = await refreshRes.json();
        return jsonResponse({ success: true, data: { action: "refresh_mark_prices", ...data[0] } });
      }

      default:
        return jsonResponse({ success: false, error: `unknown action: ${action}` }, 400);
    }
  } catch (err) {
    console.error("[price-updater] Error:", err.message);
    return jsonResponse({ success: false, error: err.message }, 500);
  }
});
