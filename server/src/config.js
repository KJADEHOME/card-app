/**
 * 卡域支付服务 - 配置中心
 * 从环境变量读取所有配置，启动时校验必填项
 */
require('dotenv').config();

const required = (key) => {
    const val = process.env[key];
    if (!val) {
        console.error(`[FATAL] 缺少必填环境变量: ${key}`);
        process.exit(1);
    }
    return val;
};

const config = {
    // 服务
    port: parseInt(process.env.PORT || '3001', 10),
    nodeEnv: process.env.NODE_ENV || 'development',
    isProd: process.env.NODE_ENV === 'production',

    // Supabase
    supabase: {
        url: required('SUPABASE_URL'),
        serviceKey: required('SUPABASE_SERVICE_KEY'),
    },

    // 支付宝
    alipay: {
        appId: process.env.ALIPAY_APP_ID || '',
        appPrivateKey: process.env.ALIPAY_APP_PRIVATE_KEY || '',
        alipayPublicKey: process.env.ALIPAY_PUBLIC_KEY || '',
        signType: process.env.ALIPAY_SIGN_TYPE || 'RSA2',
        gateway: process.env.ALIPAY_GATEWAY || 'https://openapi.alipay.com/gateway.do',
        notifyUrl: process.env.ALIPAY_NOTIFY_URL || '',
        returnUrl: process.env.ALIPAY_RETURN_URL || '',
        // 标记是否已配置（未配置时该支付方式不可用，但不阻止服务启动）
        enabled: !!(process.env.ALIPAY_APP_ID && process.env.ALIPAY_APP_PRIVATE_KEY && process.env.ALIPAY_PUBLIC_KEY),
    },

    // 微信支付
    wechat: {
        mchId: process.env.WECHAT_MCH_ID || '',
        apiV3Key: process.env.WECHAT_API_V3_KEY || '',
        certSerialNo: process.env.WECHAT_CERT_SERIAL_NO || '',
        privateKey: (process.env.WECHAT_PRIVATE_KEY || '').replace(/\\n/g, '\n'),
        platformCert: (process.env.WECHAT_PLATFORM_CERT || '').replace(/\\n/g, '\n'),
        notifyUrl: process.env.WECHAT_NOTIFY_URL || '',
        appId: process.env.WECHAT_APP_ID || '',
        enabled: !!(process.env.WECHAT_MCH_ID && process.env.WECHAT_API_V3_KEY && process.env.WECHAT_PRIVATE_KEY),
    },

    // 业务
    platformFeeRate: parseFloat(process.env.PLATFORM_FEE_RATE || '0.03'),
    autoConfirmDays: parseInt(process.env.AUTO_CONFIRM_DAYS || '7', 10),
};

module.exports = config;
