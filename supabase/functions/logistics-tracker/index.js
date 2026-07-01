// supabase/functions/logistics-tracker/index.js
// 物流轨迹查询 Edge Function
// 支持：快递100、快递鸟等 API
// 当前使用模拟数据，后续配置 API Key 后可切换真实 API

import { corsHeaders } from '../_shared/cors.js';

const MOCK_DATA = {
  'SF1234567890': [
    { time: '2026-07-01 10:00:00', status: '快递已签收，签收人：本人' },
    { time: '2026-07-01 08:30:00', status: '快递已送达，等待签收' },
    { time: '2026-06-30 20:00:00', status: '快递已到达目的地网点' },
    { time: '2026-06-30 10:00:00', status: '快递已发出，中转中' },
    { time: '2026-06-29 15:00:00', status: '快递已揽收' }
  ],
  'YT1234567890': [
    { time: '2026-07-01 09:00:00', status: '派送中，快递员：138****1234' },
    { time: '2026-06-30 18:00:00', status: '已到达目的地网点' },
    { time: '2026-06-30 08:00:00', status: '运输中' },
    { time: '2026-06-29 14:00:00', status: '已揽收' }
  ]
};

Deno.serve(async (req) => {
  // CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const { company, tracking_no } = await req.json();

    if (!company || !tracking_no) {
      return new Response(
        JSON.stringify({ error: '缺少参数：company 和 tracking_no' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // TODO: 接入真实快递 API
    // 1. 快递100: https://www.kuaidi100.com/openapi/
    // 2. 快递鸟: https://www.kdniao.com/api-track/
    // 3. 阿里云物流API: https://market.aliyun.com/products/57124001/cmapi00053574.html
    
    // 当前使用模拟数据
    let timeline = MOCK_DATA[tracking_no] || generateMockTimeline(company, tracking_no);

    return new Response(
      JSON.stringify({
        success: true,
        company: company,
        tracking_no: tracking_no,
        timeline: timeline,
        // TODO: 真实 API 返回格式
        // {
        //   "status": "签收",
        //   "list": [...]
        // }
      }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// 生成模拟物流轨迹
function generateMockTimeline(company, trackingNo) {
  const now = new Date();
  const events = [
    { time: new Date(now - 0 * 24 * 60 * 60 * 1000).toISOString(), status: '快递已签收，签收人：本人' },
    { time: new Date(now - 1 * 24 * 60 * 60 * 1000).toISOString(), status: '快递已送达，等待签收' },
    { time: new Date(now - 2 * 24 * 60 * 60 * 1000).toISOString(), status: `已到达目的地网点（${company}）` },
    { time: new Date(now - 3 * 24 * 60 * 60 * 1000).toISOString(), status: '快递运输中' },
    { time: new Date(now - 4 * 24 * 60 * 60 * 1000).toISOString(), status: '快递已揽收' }
  ];

  return events;
}

/*
=== 快递100 API 接入示例 ===

1. 注册账号：https://www.kuaidi100.com/openapi/
2. 获取 API Key
3. 在 Supabase Edge Function Secrets 中添加：
   KUAIDI100_API_KEY: "your_api_key"

4. 替换上面的逻辑为：

async function queryKuaidi100(company, trackingNo) {
  const apiKey = Deno.env.get('KUAIDI100_API_KEY');
  const url = `https://poll.kuaidi100.com/poll/query.do?customer=xxx&param={"com":"${company}","num":"${trackingNo}","from":"","to":"","resultv2":"1","show":"0","order":"desc"}&sign=${signature}`;
  
  const response = await fetch(url);
  const data = await response.json();
  
  return data.data || [];
}

*/
