const fs = require('fs');
const path = require('path');

const imagePath = process.argv[2] || 'C:\\Users\\wangy\\Desktop\\b75a0b8d086d98f7c2bfafb25d725ff9.jpg';

async function testAiScan() {
  const imageBuffer = fs.readFileSync(imagePath);
  const base64Image = imageBuffer.toString('base64');

  console.log('图片大小:', imageBuffer.length, 'bytes');
  console.log('Base64 长度:', base64Image.length);

  const endpoint = 'https://xybpcsmjjcnkjwfsuder.supabase.co/functions/v1/ai-scan';

  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer sb_publishable_DqgJ_yvf_q8IpAJ8xlMbYQ_a0sotaD7',
      'apikey': 'sb_publishable_DqgJ_yvf_q8IpAJ8xlMbYQ_a0sotaD7',
    },
    body: JSON.stringify({ image: base64Image }),
  });

  const data = await res.json();
  console.log('\n状态码:', res.status);
  console.log('响应:', JSON.stringify(data, null, 2));
}

testAiScan().catch(err => {
  console.error('测试失败:', err.message);
  process.exit(1);
});
