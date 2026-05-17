import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const MOONSHOT_API_KEY = "sk-zvSdmpMBWUpUOxfWjDyfod4dlGAnEkHnhC3P5UdcRRMFsojk";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    let image: string;
    try {
      const body = await req.json();
      image = body.image || "";
    } catch {
      return new Response(JSON.stringify({ success: false, error: "invalid JSON body" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!image || image.length < 100) {
      return new Response(JSON.stringify({
        success: false,
        error: "image too short or empty - provide a base64 encoded image"
      }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const imageUrl = image.startsWith("data:")
      ? image
      : `data:image/jpeg;base64,${image}`;

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
            {
              type: "image_url",
              image_url: { url: imageUrl }
            },
            {
              type: "text",
              text: 'Identify this trading card. Return ONLY valid JSON with keys: name (card name), series (card game: Yu-Gi-Oh/Pokemon/Magic/Other), rarity (N/R/SR/UR/SSR/SEC/PR). Example: {"name":"Dark Magician","series":"Yu-Gi-Oh","rarity":"UR"}'
            }
          ]
        }],
        temperature: 0.1
      })
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`Moonshot API error ${response.status}: ${errText}`);
    }

    const data = await response.json();
    if (data.error) {
      throw new Error(data.error.message || JSON.stringify(data.error));
    }

    const rawContent = data.choices?.[0]?.message?.content?.trim() || "{}";
    let result = { name: "unknown", series: "Yu-Gi-Oh", rarity: "N", isRare: false };
    try {
      const jsonStr = rawContent.match(/\{[\s\S]*?\}/)?.[0] || "{}";
      const parsed = JSON.parse(jsonStr);
      result = {
        name: parsed.name || "unknown",
        series: parsed.series || "Yu-Gi-Oh",
        rarity: parsed.rarity || "N",
        isRare: ["SSR", "UR", "SEC", "PR", "SR"].includes(parsed.rarity)
      };
    } catch (e) {
      result.name = rawContent.substring(0, 50);
    }

    return new Response(JSON.stringify({ success: true, data: result }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error) {
    return new Response(JSON.stringify({
      success: false,
      error: error.message || "scan failed"
    }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
