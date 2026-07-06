/**
 * 支付路由
 *   POST /api/payment/create   - 创建支付（充值 / 订单付款，支付宝/微信）
 *   GET  /api/payment/status/:paymentNo - 查询支付状态（前端轮询）
 *   POST /api/payment/balance   - 余额支付订单（冻结买家余额）
 */
const express = require('express');
const router = express.Router();
const escrow = require('../lib/escrow');
const { authMiddleware } = require('../middleware/auth');

/**
 * 创建支付
 * body: { provider, businessType, businessId, amount, subject, openid }
 */
router.post('/create', authMiddleware, async (req, res) => {
    try {
        const { provider, businessType, businessId, amount, subject, openid } = req.body;

        if (!provider || !businessType) {
            return res.status(400).json({ error: '缺少必填参数: provider, businessType' });
        }
        if (!['alipay', 'wechat'].includes(provider)) {
            return res.status(400).json({ error: '不支持的支付方式: ' + provider });
        }

        const userAgent = req.headers['user-agent'] || '';
        const clientIp = req.ip || (req.socket && req.socket.remoteAddress) || '127.0.0.1';

        const result = await escrow.createEscrowPayment({
            provider,
            businessType,
            businessId,
            amount,
            subject,
            userAgent,
            openid,
            clientIp,
        });

        res.json(result);
    } catch (err) {
        console.error('[Payment] 创建支付失败:', err.message);
        res.status(500).json({ error: err.message });
    }
});

/**
 * 查询支付状态（前端轮询用）
 */
router.get('/status/:paymentNo', authMiddleware, async (req, res) => {
    try {
        const data = await escrow.queryPaymentStatus(req.params.paymentNo);
        res.json(data);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

/**
 * 余额支付订单
 * body: { orderId }
 * 调用 DB RPC pay_with_balance（内部校验买家身份 + 余额 + 冻结资金）
 */
router.post('/balance', authMiddleware, async (req, res) => {
    try {
        const { orderId } = req.body;
        if (!orderId) {
            return res.status(400).json({ error: '缺少 orderId' });
        }

        const { data, error } = await req.userClient.rpc('pay_with_balance', {
            p_order_id: orderId,
        });

        if (error) throw new Error(error.message);
        res.json(data);
    } catch (err) {
        console.error('[Payment] 余额支付失败:', err.message);
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
