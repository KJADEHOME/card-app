import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const MOONSHOT_API_KEY = "sk-zvSdmpMBWUpUOxfWjDyfod4dlGAnEkHnhC3P5UdcRRMFsojk";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { image } = await req.json();
    if (!image) {
      return new Response(JSON.stringify({ error: "missing image" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const response = await fetch("https://api.moonshot.cn/v1/chat/completions", {
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
            { type: "image_url", image_url: { url: "data:image/jpeg;base64," + image } },
            { type: "text", text: "You are a professional card recognition expert. Identify: 1) Card game type (Yu-Gi-Oh/Pokemon/Magic/etc) 2) Card name 3) Rarity (N/R/SR/UR/SSR/SEC/PR). Return ONLY JSON: {\"name\":\"...\",\"series\":\"...\",\"rarity\":\"...\"}. Example: {\"name\":\"Blue-Eyes White Dragon\",\"series\":\"Yu-Gi-Oh\",\"rarity\":\"UR\"}" }
          ]
        }],
        temperature: 0.1
      })
    });

    const data = await response.json();
    if (data.error) throw new Error(data.error.message || JSON.stringify(data.error));

    const content = data.choices?.[0]?.message?.content?.trim() || "{}";
    let result = { name: "unknown", series: "unknown", rarity: "N" };
    try { result = JSON.parse(content.match(/\{[\s\S]*?\}/)?.[0] || "{}"); } catch(e) {}

    return new Response(JSON.stringify({ success: true, data: result }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error) {
    return new Response(JSON.stringify({ success: false, error: error.message || "scan failed" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
