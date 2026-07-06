/**
 * 鉴权中间件
 * 从 Authorization header 提取 Supabase JWT，验证用户身份
 * 为每个请求创建一个携带用户 token 的 Supabase client（用于 RLS / auth.uid()）
 */
const { createClient } = require('@supabase/supabase-js');
const config = require('../config');

// service_role client（服务端全局，用于无 RLS 限制的查询）
const serviceClient = createClient(config.supabase.url, config.supabase.serviceKey);

async function authMiddleware(req, res, next) {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        return res.status(401).json({ error: '未提供认证令牌' });
    }
    const token = authHeader.substring(7);

    const { data, error } = await serviceClient.auth.getUser(token);
    if (error || !data.user) {
        return res.status(401).json({ error: '认证失败: ' + (error ? error.message : '无效令牌') });
    }

    req.user = data.user;
    req.accessToken = token;
    // 携带用户 token 的 client，调用 SECURITY DEFINER RPC 时 auth.uid() 可正确解析
    req.userClient = createClient(config.supabase.url, config.supabase.serviceKey, {
        global: { headers: { Authorization: 'Bearer ' + token } },
    });

    next();
}

module.exports = { authMiddleware, serviceClient };
