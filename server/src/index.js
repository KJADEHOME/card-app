/**
 * 卡域支付服务 - 入口
 * Express 应用，提供支付下单、回调验签、资金担保操作 API
 *
 * 启动: node server/src/index.js
 * 环境变量: 见 server/.env.example
 */
const express = require('express');
const cors = require('cors');
const config = require('./config');
const escrow = require('./lib/escrow');

const app = express();

// CORS（PWA 前端跨域调用）
app.use(cors());

// ---- Webhook 路由（必须在 json parser 之前，需要 raw body 验签）----
app.use('/api/webhook', require('./routes/webhook'));

// ---- 其他 API 路由 ----
app.use(express.json());

// 健康检查
app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        service: 'card-app-payment',
        alipay: config.alipay.enabled ? 'enabled' : 'not_configured',
        wechat: config.wechat.enabled ? 'enabled' : 'not_configured',
        uptime: Math.floor(process.uptime()) + 's',
    });
});

app.use('/api/payment', require('./routes/payment'));
app.use('/api/escrow', require('./routes/escrow'));

// 404
app.use((req, res) => {
    res.status(404).json({ error: 'Not Found: ' + req.method + ' ' + req.path });
});

// 全局错误处理
app.use((err, req, res, next) => {
    console.error('[Server] 未捕获错误:', err.message);
    res.status(500).json({ error: '服务器内部错误' });
});

// ---- 启动 ----
const server = app.listen(config.port, () => {
    console.log('=================================');
    console.log('  卡域支付服务已启动');
    console.log('  地址: http://localhost:' + config.port);
    console.log('  支付宝: ' + (config.alipay.enabled ? '已启用' : '未配置'));
    console.log('  微信支付: ' + (config.wechat.enabled ? '已启用' : '未配置'));
    console.log('  手续费率: ' + (config.platformFeeRate * 100) + '%');
    console.log('  自动确认: ' + config.autoConfirmDays + ' 天');
    console.log('=================================');
});

// ---- 定时任务: 超时自动确认收货（每 30 分钟）----
const AUTO_CONFIRM_INTERVAL = 30 * 60 * 1000;
setInterval(async () => {
    try {
        const result = await escrow.autoConfirmOrders();
        if (result.success && result.auto_confirmed_count > 0) {
            console.log('[定时任务] 自动确认 ' + result.auto_confirmed_count + ' 笔订单');
        }
    } catch (err) {
        console.error('[定时任务] 自动确认失败:', err.message);
    }
}, AUTO_CONFIRM_INTERVAL);

// ---- 优雅关闭 ----
process.on('SIGTERM', () => {
    console.log('[卡域支付服务] 收到 SIGTERM，正在关闭...');
    server.close(() => {
        console.log('[卡域支付服务] 已关闭');
        process.exit(0);
    });
});

process.on('SIGINT', () => {
    server.close(() => process.exit(0));
});

module.exports = app;
