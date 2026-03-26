import OpenAI from 'openai';

const client = new OpenAI({
  apiKey: process.env.MOONSHOT_API_KEY,
  baseURL: 'https://api.moonshot.cn/v1'
});

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { message, history } = req.body;

  const messages = [
    { role: 'system', content: '你是一个帮我开发卡牌页面的前端专家，请用中文回答，代码要整洁。' },
    ...(history || []),
    { role: 'user', content: message }
  ];

  try {
    const response = await client.chat.completions.create({
      model: 'kimi-k2.5',
      messages,
      temperature: 1,
    });
    res.status(200).json({ reply: response.choices[0].message.content });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: 'AI 服务暂时不可用，请稍后再试' });
  }
}