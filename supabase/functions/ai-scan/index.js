// ai-scan Edge Function v2 — Risk Control Edition
// Features: 7-day cache, rate limit, cost logging, risk check, timestamp validation
// Pure JavaScript (no TypeScript imports) — runs on Deno
"use strict";

const MOONSHOT_API_KEY = Deno.env.get("MOONSHOT_API_KEY") || "sk-zvSdmpMBWUpUOxfWjDyfod4dlGAnEkHnhC3P5UdcRRMFsojk";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co";
const SB_SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") || "";

const MODEL_NAME = "moonshot-v1-128k-vision-preview";
const ESTIMATED_COST_CNY = 0.015; // 每次AI调用预估成本(元)

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, X-User-Id, X-Timestamp, X-Request-Sig",
};

function jsonResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

// Compute SHA-256 hash of image for dedup & cache
async function computeImageHash(base64Image) {
  try {
    const binaryStr = atob(base64Image);
    const bytes = new Uint8Array(binaryStr.length);
    for (let i = 0; i < binaryStr.length; i++) {
      bytes[i] = binaryStr.charCodeAt(i);
    }
    const hashBuffer = await crypto.subtle.digest("SHA-256", bytes);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
  } catch (e) {
    console.error("Hash computation error:", e);
    return null;
  }
}

// Call Supabase RPC (service role)
async function callRPC(functionName, params) {
  if (!SB_SERVICE_KEY) return null;
  try {
    const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${functionName}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": SB_SERVICE_KEY,
        "Authorization": `Bearer ${SB_SERVICE_KEY}`,
      },
      body: JSON.stringify(params),
    });
    return await resp.json();
  } catch (e) {
    console.error(`RPC ${functionName} error:`, e);
    return null;
  }
}

// Timestamp validation (reject requests older than 60s)
function validateTimestamp(ts) {
  if (!ts) return true; // optional, don't block if not provided
  const now = Math.floor(Date.now() / 1000);
  const requestTs = parseInt(ts);
  if (isNaN(requestTs)) return false;
  return Math.abs(now - requestTs) < 60; // 60s window
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ success: false, error: "Method not allowed" }, 405);
  }

  try {
    let body;
    try {
      body = await req.json();
    } catch {
      return jsonResponse({ success: false, error: "invalid JSON body" }, 400);
    }

    // Extract user_id from header (client sends it)
    const userId = req.headers.get("X-User-Id") || body.user_id || "";
    const timestamp = req.headers.get("X-Timestamp") || body.timestamp || "";
    const clientIP = req.headers.get("X-Forwarded-For") || req.headers.get("X-Client-IP") || "";

    // Timestamp validation (anti-replay)
    if (!validateTimestamp(timestamp)) {
      return jsonResponse({ success: false, error: "请求已过期，请重试" }, 401);
    }

    const image = body.image || "";
    if (!image || image.length < 100) {
      return jsonResponse({
        success: false,
        error: "image too short or empty — provide a base64 encoded image"
      }, 400);
    }

    // Compute image hash first (needed for cache check)
    const imageHash = await computeImageHash(image);
    if (!imageHash) {
      return jsonResponse({ success: false, error: "无法计算图片指纹" }, 500);
    }

    // ============================================================
    // Step 1: Check cache — if hit, return cached result (no AI call, no cost)
    // ============================================================
    if (userId && SB_SERVICE_KEY) {
      const cacheResult = await callRPC("get_cached_scan_result", { p_image_hash: imageHash });
      if (cacheResult && cacheResult.cached === true && cacheResult.data) {
        console.log("[ai-scan] Cache HIT — returning cached result, no AI call");
        return jsonResponse({
          success: true,
          data: {
            ...cacheResult.data,
            image_hash: imageHash,
            cached: true,
            cached_at: cacheResult.cached_at,
          }
        });
      }
    }

    // ============================================================
    // Step 2: Rate limit check (daily + per-minute + risk level)
    // ============================================================
    if (userId && SB_SERVICE_KEY) {
      const rateCheck = await callRPC("check_ai_rate_limit", { p_user_id: userId });
      if (rateCheck && rateCheck.length > 0) {
        const r = rateCheck[0];
        if (r.risk_blocked) {
          return jsonResponse({ success: false, error: r.error_msg, risk_blocked: true }, 403);
        }
        if (!r.can_scan) {
          return jsonResponse({
            success: false,
            error: r.error_msg,
            rate_limited: true,
            daily_used: r.daily_used,
            daily_limit: r.daily_limit,
            cooldown_remaining: r.cooldown_remaining,
          }, 429);
        }
      }
    }

    // ============================================================
    // Step 3: AI cost budget check
    // ============================================================
    if (userId && SB_SERVICE_KEY) {
      const budgetCheck = await callRPC("check_ai_cost_budget", { p_user_id: userId });
      if (budgetCheck && budgetCheck.length > 0) {
        const b = budgetCheck[0];
        if (!b.can_call) {
          return jsonResponse({
            success: false,
            error: "今日AI识别预算已用尽，请明天再来",
            budget_exceeded: true,
            today_cost: b.today_cost,
            daily_limit: b.daily_limit,
          }, 429);
        }
      }
    }

    // ============================================================
    // Step 4: Call Moonshot AI API
    // ============================================================
    const imageUrl = image.startsWith("data:") ? image : "data:image/jpeg;base64," + image;

    const moonshotRes = await fetch("https://api.moonshot.cn/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + MOONSHOT_API_KEY,
      },
      body: JSON.stringify({
        model: MODEL_NAME,
        messages: [{
          role: "user",
          content: [
            { type: "image_url", image_url: { url: imageUrl } },
            {
              type: "text",
              text: `Look at this trading card image carefully. Identify the card and return EXACTLY this JSON format (no markdown, no extra text):
{"name":"Card Name Here","series":"Game Name","rarity":"RarityCode"}

Rules:
- name: The card's English name. If the card has Japanese/Chinese text, translate to English.
- series: Must be one of: "Pokemon", "Yu-Gi-Oh", "Magic", "Nikke", "Brown Dust", "Stellar Blade", "Other"
- rarity: Must be one of: "N", "R", "SR", "UR", "SSR", "SEC", "PR"

CRITICAL: Output ONLY the JSON object. No explanations. No markdown code blocks. Just the raw JSON.`
            }
          ]
        }],
        temperature: 0.1,
        max_tokens: 300,
      }),
    });

    if (!moonshotRes.ok) {
      const errText = await moonshotRes.text();
      throw new Error("Moonshot API error " + moonshotRes.status + ": " + errText);
    }

    const data = await moonshotRes.json();
    if (data.error) {
      throw new Error(data.error.message || JSON.stringify(data.error));
    }

    const rawContent = (data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) || "";

    // Clean up: remove markdown code fences, extra whitespace, BOM
    let cleaned = rawContent
      .replace(/```json\s*/gi, "")
      .replace(/```\s*/g, "")
      .replace(/^\uFEFF/, "")
      .trim();

    // Remove any non-printable/garbled characters
    cleaned = cleaned.replace(/[^\x20-\x7E\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff\uac00-\ud7af\u0600-\u06ff\u0400-\u04ff\u00c0-\u024f\u00a0-\u00ff]/g, "");

    let result = { name: "unknown", series: "Yu-Gi-Oh", rarity: "N", isRare: false };

    if (cleaned) {
      let parsed = null;
      try {
        parsed = JSON.parse(cleaned);
      } catch (_) {
        const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
        if (jsonMatch) {
          try {
            parsed = JSON.parse(jsonMatch[0]);
          } catch (__) {}
        }
      }

      if (parsed && parsed.name && typeof parsed.name === "string") {
        let name = String(parsed.name).trim();
        if (name.length > 100) name = name.substring(0, 80);
        result.name = name || "unknown";
        result.series = String(parsed.series || "Yu-Gi-Oh").trim();
        result.rarity = String(parsed.rarity || "N").trim();
        result.isRare = ["SSR", "UR", "SEC", "PR", "SR"].indexOf(result.rarity) !== -1;
      } else {
        const fallback = cleaned.substring(0, 50).replace(/[{}\[\]"':,\n\r\t]/g, "").trim();
        result.name = fallback || "unknown";
      }
    }

    // Extract token usage for cost tracking
    const inputTokens = (data.usage && data.usage.prompt_tokens) || 0;
    const outputTokens = (data.usage && data.usage.completion_tokens) || 0;

    // ============================================================
    // Step 5: Cache the result (7-day TTL)
    // ============================================================
    if (userId && SB_SERVICE_KEY) {
      const resultJson = JSON.stringify(result);
      await callRPC("cache_scan_result", {
        p_user_id: userId,
        p_image_hash: imageHash,
        p_result_json: resultJson,
        p_card_name: result.name,
        p_series: result.series,
        p_rarity: result.rarity,
        p_cost_cny: ESTIMATED_COST_CNY,
      });

      // ============================================================
      // Step 6: Log AI cost
      // ============================================================
      await callRPC("record_ai_cost", {
        p_user_id: userId,
        p_cost_cny: ESTIMATED_COST_CNY,
        p_request_type: "card_scan",
        p_model: MODEL_NAME,
        p_input_tokens: inputTokens,
        p_output_tokens: outputTokens,
        p_cached: false,
        p_image_hash: imageHash,
      });

      // ============================================================
      // Step 7: Evaluate risk level (async, non-blocking)
      // ============================================================
      // Don't await — fire and forget
      callRPC("evaluate_user_risk", { p_user_id: userId }).catch(() => {});
    }

    return jsonResponse({
      success: true,
      data: {
        ...result,
        image_hash: imageHash,
        cached: false,
        cost_cny: ESTIMATED_COST_CNY,
      }
    });

  } catch (error) {
    const msg = error.message || "scan failed";
    console.error("ai-scan error:", msg);
    return jsonResponse({ success: false, error: msg }, 500);
  }
});
