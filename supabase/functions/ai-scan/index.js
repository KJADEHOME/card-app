// ai-scan Edge Function — Pure JavaScript (no TypeScript imports)
// Supports: Pokemon, Yu-Gi-Oh, Magic, Nikke, Brown Dust, Stellar Blade
// Returns image_hash for client-side dedup
"use strict";

const MOONSHOT_API_KEY = Deno.env.get("MOONSHOT_API_KEY") || "sk-zvSdmpMBWUpUOxfWjDyfod4dlGAnEkHnhC3P5UdcRRMFsojk";

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

// Compute SHA-256 hash of image for dedup
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

    const image = body.image || "";
    if (!image || image.length < 100) {
      return jsonResponse({
        success: false,
        error: "image too short or empty — provide a base64 encoded image"
      }, 400);
    }

    // Compute image hash (runs in parallel with AI call)
    const imageHashPromise = computeImageHash(image);

    const imageUrl = image.startsWith("data:") ? image : "data:image/jpeg;base64," + image;

    const moonshotRes = await fetch("https://api.moonshot.cn/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + MOONSHOT_API_KEY,
      },
      body: JSON.stringify({
        model: "moonshot-v1-128k-vision-preview",
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
    
    // Remove any non-printable/garbled characters (keep common Unicode ranges)
    cleaned = cleaned.replace(/[^\x20-\x7E\u4e00-\u9fff\u3040-\u309f\u30a0-\u30ff\uac00-\ud7af\u0600-\u06ff\u0400-\u04ff\u00c0-\u024f\u00a0-\u00ff]/g, "");

    let result = { name: "unknown", series: "Yu-Gi-Oh", rarity: "N", isRare: false };
    
    if (cleaned) {
      // Try strict JSON parse first
      let parsed = null;
      try {
        parsed = JSON.parse(cleaned);
      } catch (_) {
        // Try extracting JSON with regex
        const jsonMatch = cleaned.match(/\{[\s\S]*\}/);
        if (jsonMatch) {
          try {
            parsed = JSON.parse(jsonMatch[0]);
          } catch (__) {
            // JSON extraction failed
          }
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

    // Get image hash
    const imageHash = await imageHashPromise;

    return jsonResponse({
      success: true,
      data: {
        ...result,
        image_hash: imageHash
      }
    });

  } catch (error) {
    const msg = error.message || "scan failed";
    console.error("ai-scan error:", msg);
    return jsonResponse({ success: false, error: msg }, 500);
  }
});
