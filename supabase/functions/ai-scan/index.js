// ai-scan Edge Function — Pure JavaScript (no TypeScript imports)
// This file is pure Deno/JavaScript — Management API can deploy it directly
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
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
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
              text: 'Identify this trading card. Return ONLY valid JSON with keys: name (card name), series (card game: Yu-Gi-Oh/Pokemon/Magic/Other), rarity (N/R/SR/UR/SSR/SEC/PR). Example: {"name":"Dark Magician","series":"Yu-Gi-Oh","rarity":"UR"}'
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
    const trimmed = rawContent.trim();

    let result = { name: "unknown", series: "Yu-Gi-Oh", rarity: "N", isRare: false };
    if (trimmed) {
      try {
        const jsonMatch = trimmed.match(/\{[\s\S]*?\}/);
        if (jsonMatch) {
          const parsed = JSON.parse(jsonMatch[0]);
          result = {
            name: parsed.name || "unknown",
            series: parsed.series || "Yu-Gi-Oh",
            rarity: parsed.rarity || "N",
            isRare: ["SSR", "UR", "SEC", "PR", "SR"].indexOf(parsed.rarity) !== -1,
          };
        }
      } catch (_e) {
        // JSON parse failed — use fallback
        result.name = trimmed.substring(0, 60);
      }
    }

    return jsonResponse({ success: true, data: result });

  } catch (error) {
    const msg = error.message || "scan failed";
    console.error("ai-scan error:", msg);
    return jsonResponse({ success: false, error: msg }, 500);
  }
});
