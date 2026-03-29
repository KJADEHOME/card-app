import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const MOONSHOT_API_KEY = "sk-zvSdmpMBWUpUOxfWjDyfod4dlGAnEkHnhC3P5UdcRRMFsojk";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
      },
    });
  }

  try {
    const { image } = await req.json();
    
    const response = await fetch("https://api.moonshot.cn/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + MOONSHOT_API_KEY,
      },
      body: JSON.stringify({
        model: "moonshot-v1-8k-vision",
        messages: [{
          role: "user",
          content: [
            { type: "image_url", image_url: { url: "data:image/jpeg;base64," + image } },
            { type: "text", text: "这是一张卡牌图片，请识别这是什么卡牌。只返回卡牌名称和系列，格式：卡牌名称|系列。例如：青眼白龙|游戏王" }
          ]
        }],
        temperature: 0.1
      })
    });

    const data = await response.json();
    
    return new Response(JSON.stringify(data), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
    });
  }
});
