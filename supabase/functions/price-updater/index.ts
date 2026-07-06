// price-updater Edge Function v4 — 市场价格波动 + 资产市场化 + 价格趋势
// Supported actions:
//   fluctuate          — 价格波动 → 同步 → card_market → portfolio → 快照 → 每日定价快照（完整流水线）
//   sync               — 仅同步用户资产价格
//   seed               — 从 price_history 初始化 card_prices
//   market_seed        — 从 card_prices 初始化 card_market
//   portfolio_sync     — 从 user_collections 同步到 portfolio_items
//   portfolio_refresh  — 刷新所有用户 user_portfolio
//   snapshot           — 仅生成资产快照
//   price_snapshot     — 每日定价快照 card_market.final_price → price_history.daily_price
"use strict";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
};

function jsonResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

// Edge Function secrets are set via Supabase Dashboard → Edge Functions → price-updater → Secrets.
const SERVICE_ROLE_KEY = Deno.env.get("SERVICE_ROLE_KEY") || "";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ success: false, error: "Method not allowed" }, 405);
  }

  try {
    // Check auth — require service_role key or admin auth
    const authHeader = req.headers.get("authorization") || "";
    const apiKey = req.headers.get("apikey") || "";
    const providedKey = authHeader.replace("Bearer ", "") || apiKey;
    
    if (SERVICE_ROLE_KEY && providedKey !== SERVICE_ROLE_KEY) {
      return jsonResponse({ success: false, error: "unauthorized" }, 401);
    }

    const body = await req.json();
    const action = body.action || "fluctuate";
    const market = body.market || "CN";

    switch (action) {
      case "fluctuate": {
        // 价格波动
        const maxChange = body.max_change_pct || 8;
        const minChange = body.min_change_pct || 1;
        
        const fluctuateRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/simulate_market_fluctuation`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({
              p_market: market,
              p_max_change_pct: maxChange,
              p_min_change_pct: minChange,
            }),
          }
        );

        if (!fluctuateRes.ok) {
          const err = await fluctuateRes.text();
          return jsonResponse({ success: false, error: "fluctuation RPC failed: " + err }, 500);
        }

        const fluctuateData = await fluctuateRes.json();

        // 同步用户资产价格
        const syncRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/sync_user_collections_prices`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_user_id: null }),
          }
        );

        let synced = 0;
        if (syncRes.ok) {
          const syncData = await syncRes.json();
          synced = syncData[0]?.cards_synced || 0;
        }

        // 生成资产快照
        const snapRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/take_asset_snapshot`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
          }
        );

        let snapshots = 0;
        if (snapRes.ok) {
          const snapData = await snapRes.json();
          snapshots = snapData[0]?.snapshots_taken || 0;
        }

        // Phase 7: 同步 card_market（触发器自动同步，此处手动 seed 确保完整性）
        const marketSeedRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/seed_card_market`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_market: market }),
          }
        );
        let marketSeeded = 0;
        if (marketSeedRes.ok) {
          const msData = await marketSeedRes.json();
          marketSeeded = msData[0]?.cards_seeded || 0;
        }

        // Phase 7: 刷新所有用户资产组合
        const portfolioRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/refresh_all_portfolios`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
          }
        );
        let portfoliosRefreshed = 0;
        if (portfolioRes.ok) {
          const pfData = await portfolioRes.json();
          portfoliosRefreshed = pfData[0]?.users_refreshed || 0;
        }

        // Phase 7.5: 每日定价快照 card_market.final_price → price_history.daily_price
        const priceSnapRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/take_daily_price_snapshot`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_market: market }),
          }
        );
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
            // Phase 7 新增
            market_cards_seeded: marketSeeded,
            portfolios_refreshed: portfoliosRefreshed,
            // Phase 7.5 新增
            price_snapshots: priceSnapshots,
          },
        });
      }

      case "sync": {
        // 仅同步用户资产价格（不波动）
        const syncRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/sync_user_collections_prices`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_user_id: null }),
          }
        );

        if (!syncRes.ok) {
          return jsonResponse({ success: false, error: "sync RPC failed" }, 500);
        }

        const data = await syncRes.json();
        return jsonResponse({ success: true, data: { action: "sync", ...data[0] } });
      }

      case "seed": {
        // 从 price_history 初始化 card_prices
        const seedRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/seed_card_prices_from_history`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_market: market }),
          }
        );

        if (!seedRes.ok) {
          return jsonResponse({ success: false, error: "seed RPC failed" }, 500);
        }

        const data = await seedRes.json();
        return jsonResponse({ success: true, data: { action: "seed", ...data[0] } });
      }

      case "snapshot": {
        // 仅生成资产快照
        const snapRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/take_asset_snapshot`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
          }
        );

        if (!snapRes.ok) {
          return jsonResponse({ success: false, error: "snapshot RPC failed" }, 500);
        }

        const data = await snapRes.json();
        return jsonResponse({ success: true, data: { action: "snapshot", ...data[0] } });
      }

      // ===== Phase 7 新增 actions =====

      case "market_seed": {
        // 从 card_prices 初始化 card_market
        const seedRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/seed_card_market`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_market: market }),
          }
        );

        if (!seedRes.ok) {
          const err = await seedRes.text();
          return jsonResponse({ success: false, error: "market_seed RPC failed: " + err }, 500);
        }

        const data = await seedRes.json();
        return jsonResponse({ success: true, data: { action: "market_seed", ...data[0] } });
      }

      case "portfolio_sync": {
        // 从 user_collections 迁移到 portfolio_items
        const syncRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/sync_collections_to_portfolio`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_user_id: null }),
          }
        );

        if (!syncRes.ok) {
          const err = await syncRes.text();
          return jsonResponse({ success: false, error: "portfolio_sync RPC failed: " + err }, 500);
        }

        const data = await syncRes.json();
        return jsonResponse({ success: true, data: { action: "portfolio_sync", ...data[0] } });
      }

      case "portfolio_refresh": {
        // 刷新所有用户资产组合（从 portfolio_items → user_portfolio）
        const refreshRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/refresh_all_portfolios`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
          }
        );

        if (!refreshRes.ok) {
          const err = await refreshRes.text();
          return jsonResponse({ success: false, error: "portfolio_refresh RPC failed: " + err }, 500);
        }

        const data = await refreshRes.json();
        return jsonResponse({ success: true, data: { action: "portfolio_refresh", ...data[0] } });
      }

      // ===== Phase 7.5 新增 action =====

      case "price_snapshot": {
        // 每日定价快照：card_market.final_price → price_history.daily_price
        const snapRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/take_daily_price_snapshot`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_market: market }),
          }
        );

        if (!snapRes.ok) {
          const err = await snapRes.text();
          return jsonResponse({ success: false, error: "price_snapshot RPC failed: " + err }, 500);
        }

        const data = await snapRes.json();
        return jsonResponse({ success: true, data: { action: "price_snapshot", ...data[0] } });
      }

      // ===== Phase 8 新增：mark_price 刷新 =====

      case "refresh_mark_prices": {
        // 批量刷新所有卡的 mark_price（触发触发器重算）
        const refreshRes = await fetch(
          `${Deno.env.get("PROJECT_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co"}/rest/v1/rpc/refresh_all_mark_prices`,
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "apikey": providedKey,
              "Authorization": `Bearer ${providedKey}`,
            },
            body: JSON.stringify({ p_market: market }),
          }
        );

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
