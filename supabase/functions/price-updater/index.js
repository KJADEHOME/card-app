// price-updater Edge Function — 市场价格模拟波动 + 同步
// Supported actions: fluctuate (波动所有价格), sync (同步用户资产), seed (初始化价格)
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

        return jsonResponse({
          success: true,
          data: {
            action: "fluctuate",
            market,
            ...fluctuateData[0],
            cards_synced: synced,
            snapshots_taken: snapshots,
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

      default:
        return jsonResponse({ success: false, error: `unknown action: ${action}` }, 400);
    }
  } catch (err) {
    console.error("[price-updater] Error:", err.message);
    return jsonResponse({ success: false, error: err.message }, 500);
  }
});
