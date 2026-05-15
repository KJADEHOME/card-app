import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const MOONSHOT_API_KEY = Deno.env.get("MOONSHOT_API_KEY")!;

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
      return new Response(JSON.stringify({ error: "缺少图片数据" }), {
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
            { type: "text", text: `你是一个专业的卡牌识别助手。请仔细识别这张卡牌图片：
1. 首先确认这是哪种卡牌游戏（游戏王/宝可梦/万智牌/数码宝贝等）
2. 识别卡牌名称，注意卡牌名称通常印在卡牌中央或上方
3. 识别卡牌右下角的稀有度标志（N/R/SR/UR/SSR/SEC/PR等）
4. 如果是罕见稀有度（SR及以上）或限量版，在最后加[稀有]

返回格式（只返回这一行，不要其他文字）：
卡牌名称|系列|稀有度

例如：青眼白龙|游戏王|UR[稀有]
如果无法确定卡牌名称，返回：未知卡牌|无法识别|无` }
          ]
        }],
        temperature: 0.1
      })
    });

    const data = await response.json();

    if (data.error) {
      throw new Error(data.error.message || JSON.stringify(data.error));
    }

    // 解析AI返回内容
    const content = data.choices?.[0]?.message?.content?.trim() || "";
    const parts = content.split("|");
    const name = parts[0]?.trim() || "未知卡牌";
    const series = parts[1]?.trim() || "未知系列";
    let rarity = parts[2]?.trim() || "";

    const isRare = rarity.includes("[稀有]") ||
                   /SSR|UR|SEC|PR[SR]?/i.test(rarity) ||
                   rarity.includes("限量");

    rarity = rarity.replace("[稀有]", "").trim();

    return new Response(JSON.stringify({
      success: true,
      data: { name, series, rarity, isRare }
    }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (error) {
    return new Response(JSON.stringify({
      success: false,
      error: error.message || "识别失败，请重试"
    }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
