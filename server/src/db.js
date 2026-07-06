/**
 * 卡域支付服务 - Supabase 客户端
 * 使用 service_role 密钥，拥有完全数据库访问权限
 */
const { createClient } = require('@supabase/supabase-js');
const config = require('./config');

const supabase = createClient(
    config.supabase.url,
    config.supabase.serviceKey,
    {
        auth: { persistSession: false, autoRefreshToken: false },
    }
);

module.exports = supabase;
