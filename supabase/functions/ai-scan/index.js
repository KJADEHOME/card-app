// ai-scan Edge Function v3 — Fault Tolerance Edition
// Features: Gemini API, 3-level classification (TCG/NON_TCG/UNKNOWN), confidence scoring
// Pure JavaScript (no TypeScript imports) — runs on Deno
"use strict";

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "https://xybpcsmjjcnkjwfsuder.supabase.co";
const SB_SERVICE_KEY = Deno.env.get("SB_SERVICE_ROLE_KEY") || "";

const MODEL_NAME = "gemini-2.0-flash";
const GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/" + MODEL_NAME + ":generateContent?key=" + GEMINI_API_KEY;
const ESTIMATED_COST_CNY = 0.0; // Gemini free tier — $0 cost

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, X-User-Id, X-Timestamp",
};

function jsonResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status: status || 200,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });
}

// Compute SHA-256 hash of image
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
    console.error("Hash error:", e);
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
  if (!ts) return true;
  const now = Math.floor(Date.now() / 1000);
  const requestTs = parseInt(ts);
  if (isNaN(requestTs)) return false;
  return Math.abs(now - requestTs) < 60;
}

// ============================================================
// Gemini AI Vision Classification Prompt
// ============================================================
const CLASSIFICATION_PROMPT = `You are a TCG card grading expert. Analyze this trading card image carefully.

STEP 1 — Classify the card TYPE:
- "TCG": standard trading card games — Yu-Gi-Oh, Pokemon, Magic: The Gathering, Digimon, One Piece TCG, Dragon Ball, Weiss Schwarz, etc. These have recognizable card frames, attack/defense numbers, set codes, and standard TCG layout.
- "NON_TCG": other collectible cards that are NOT standard TCG — mobile game IP cards (Nikke/Goddess of Victory, Brown Dust/Brave Nine, Stellar Blade, Genshin Impact, Arknights, etc.), esports team photo cards (T1, DRX, etc.), K-pop idol cards, sports cards, anime character bromide cards. These typically have full-art character illustrations without TCG gameplay elements.
- "UNKNOWN": completely unrecognizable, not a card, or too blurry to identify.

STEP 2 — Identify (if possible):
- card_name: The card/character name in English. For Japanese/Korean cards, translate to English. For character cards, give the character name.
- game: The game/franchise the card belongs to.
- confidence: Your certainty from 0.0 to 1.0.
- suggested_cards: Array of 1-3 alternative candidates if uncertain (empty array if very confident).
- reason: One-line explanation of your classification (e.g., "Standard Yu-Gi-Oh card frame with ATK/DEF stats visible" or "Full-art character illustration, no TCG gameplay elements — likely a mobile game collectible card").

STEP 3 — Output Rules:
- If TCG with high confidence (>0.8): card_name and game MUST be filled accurately.
- If NON_TCG: set type="NON_TCG", try to identify card_name and game if possible.
- If UNKNOWN: set type="UNKNOWN", card_name="", game="", confidence<0.3.

CRITICAL: Return ONLY the JSON object. No markdown. No code blocks. No extra text.`;

Deno.serve(async (req) => {
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

    const userId = req.headers.get("X-User-Id") || body.user_id || "";
    const timestamp = req.headers.get("X-Timestamp") || body.timestamp || "";

    // Timestamp validation
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

    // Compute image hash
    const imageHash = await computeImageHash(image);
    if (!imageHash) {
      return jsonResponse({ success: false, error: "无法计算图片指纹" }, 500);
    }

    // ============================================================
    // Step 1: Cache check (TCG results only, 7-day TTL)
    // ============================================================
    if (userId && SB_SERVICE_KEY) {
      const cacheResult = await callRPC("get_cached_scan_result", { p_image_hash: imageHash });
      if (cacheResult && cacheResult.cached === true && cacheResult.data) {
        console.log("[ai-scan] Cache HIT");
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
    // Step 2: Rate limit check
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
          }, 429);
        }
      }
    }

    // ============================================================
    // Step 4: Clean and prepare image for Gemini
    // ============================================================
    // Strip data:image prefix if present, Gemini needs raw base64
    let cleanBase64 = image;
    if (image.includes(",")) {
      cleanBase64 = image.split(",")[1] || image;
    }
    // Detect MIME type
    let mimeType = "image/jpeg";
    if (image.startsWith("data:image/png")) mimeType = "image/png";
    else if (image.startsWith("data:image/webp")) mimeType = "image/webp";

    // ============================================================
    // Step 5: Call Gemini API
    // ============================================================
    console.log("[ai-scan] Calling Gemini API...");

    const geminiReq = {
      contents: [{
        parts: [
          { text: CLASSIFICATION_PROMPT },
          { inline_data: { mime_type: mimeType, data: cleanBase64 } }
        ]
      }],
      generationConfig: {
        temperature: 0.1,
        maxOutputTokens: 500,
        response_mime_type: "application/json",
        response_schema: {
          type: "object",
          properties: {
            type: { type: "string", enum: ["TCG", "NON_TCG", "UNKNOWN"] },
            confidence: { type: "number" },
            card_name: { type: "string" },
            game: { type: "string" },
            suggested_cards: { type: "array", items: { type: "string" } },
            reason: { type: "string" }
          },
          required: ["type", "confidence", "card_name", "game"]
        }
      }
    };

    const geminiRes = await fetch(GEMINI_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(geminiReq),
    });

    if (!geminiRes.ok) {
      const errText = await geminiRes.text();
      console.error("[ai-scan] Gemini API error:", geminiRes.status, errText);
      throw new Error("Gemini API error " + geminiRes.status + ": " + errText.substring(0, 200));
    }

    const geminiData = await geminiRes.json();
    console.log("[ai-scan] Gemini response received");

    // Parse Gemini structured output
    let classification = {
      type: "UNKNOWN",
      confidence: 0.0,
      card_name: "",
      game: "",
      suggested_cards: [],
      reason: "AI未能识别此卡牌"
    };

    const rawText = geminiData.candidates?.[0]?.content?.parts?.[0]?.text || "";
    if (rawText) {
      try {
        const parsed = JSON.parse(rawText);
        if (parsed.type && ["TCG", "NON_TCG", "UNKNOWN"].includes(parsed.type)) {
          classification = {
            type: parsed.type,
            confidence: Number(parsed.confidence) || 0,
            card_name: String(parsed.card_name || "").trim(),
            game: String(parsed.game || "").trim(),
            suggested_cards: Array.isArray(parsed.suggested_cards) ? parsed.suggested_cards.slice(0, 3) : [],
            reason: String(parsed.reason || "无").trim()
          };
        }
      } catch (parseErr) {
        console.error("[ai-scan] JSON parse error, raw:", rawText.substring(0, 200));
        // Fallback: try extracting JSON from text
        const jsonMatch = rawText.match(/\{[\s\S]*\}/);
        if (jsonMatch) {
          try {
            const parsed = JSON.parse(jsonMatch[0]);
            if (parsed.type && ["TCG", "NON_TCG", "UNKNOWN"].includes(parsed.type)) {
              classification.type = parsed.type;
              classification.confidence = Number(parsed.confidence) || 0;
              classification.card_name = String(parsed.card_name || "").trim();
              classification.game = String(parsed.game || "").trim();
              classification.suggested_cards = Array.isArray(parsed.suggested_cards) ? parsed.suggested_cards.slice(0, 3) : [];
              classification.reason = String(parsed.reason || "无").trim();
            }
          } catch (e2) { /* use fallback */ }
        }
      }
    }

    // Cap and sanitize
    classification.confidence = Math.max(0, Math.min(1, classification.confidence));
    classification.card_name = classification.card_name.substring(0, 100);
    classification.game = classification.game.substring(0, 50);

    console.log(`[ai-scan] Classification: type=${classification.type}, confidence=${classification.confidence}, name="${classification.card_name}", game="${classification.game}"`);

    // Token usage for cost tracking
    const inputTokens = geminiData.usageMetadata?.promptTokenCount || 0;
    const outputTokens = geminiData.usageMetadata?.candidatesTokenCount || 0;

    // ============================================================
    // Step 6: Cache & Log (only for TCG with good confidence)
    // ============================================================
    if (userId && SB_SERVICE_KEY) {
      const isCacheable = classification.type === "TCG" && classification.confidence >= 0.7;

      if (isCacheable) {
        const resultJson = JSON.stringify(classification);
        await callRPC("cache_scan_result", {
          p_user_id: userId,
          p_image_hash: imageHash,
          p_result_json: resultJson,
          p_card_name: classification.card_name,
          p_series: classification.game,
          p_rarity: "N",
          p_cost_cny: ESTIMATED_COST_CNY,
        });
      }

      // Log AI cost
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

      // Fire-and-forget risk evaluation
      callRPC("evaluate_user_risk", { p_user_id: userId }).catch(() => {});
    }

    // ============================================================
    // Step 7: Build response
    // ============================================================
    const responseData = {
      card_type: classification.type,
      confidence: classification.confidence,
      card_name: classification.card_name,
      game: classification.game,
      suggested_cards: classification.suggested_cards,
      reason: classification.reason,
      // Backward compatibility fields
      name: classification.card_name || "unknown",
      series: classification.game || "unknown",
      rarity: "N",
      isRare: false,
      image_hash: imageHash,
      cached: false,
    };

    return jsonResponse({
      success: true,
      data: responseData
    });

  } catch (error) {
    const msg = error.message || "scan failed";
    console.error("[ai-scan] Fatal error:", msg);
    return jsonResponse({ success: false, error: msg }, 500);
  }
});
