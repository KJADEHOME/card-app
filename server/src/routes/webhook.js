/**
 * 支付回调路由（支付宝 / 微信）
 *   POST /api/webhook/alipay  - 支付宝异步通知（form-urlencoded）
 *   POST /api/webhook/wechat  - 微信支付通知（JSON，需 raw body 验签）
 *
 * ⚠️ 这两个路由必须在 express.json() 之前注册，以确保拿到原始 body
 */
const express = require('express');
const router = express.Router();
const escrow = require('../lib/escrow');

/**
 * 支付宝异步回调
 * 支付宝要求返回纯文本 "success"（小写）
 */
router.post('/alipay', express.urlencoded({ extended: false }), async (req, res) => {
    try {
        console.log('[Webhook] 支付宝回调 out_trade_no:', req.body.out_trade_no, 'trade_status:', req.body.trade_status);

        const result = await escrow.handlePaymentNotify('alipay', req.body, null, null);

        if (result.success) {
            res.send('success');
        } else {
            console.error('[Webhook] 支付宝回调处理失败:', result.error);
            res.send('fail');
        }
    } catch (err) {
        console.error('[Webhook] 支付宝回调异常:', err.message);
        res.send('fail');
    }
});

/**
 * 微信支付回调
 * 微信 v3 要求返回 JSON { code: 'SUCCESS' }
 */
router.post('/wechat', express.raw({ type: '*/*' }), async (req, res) => {
    try {
        const rawBody = Buffer.isBuffer(req.body) ? req.body.toString('utf8') : String(req.body);

        let notifyData;
        try {
            notifyData = JSON.parse(rawBody);
        } catch (e) {
            return res.status(400).json({ code: 'FAIL', message: '无效的 JSON' });
        }

        console.log('[Webhook] 微信回调 event_type:', notifyData.event_type);

        const result = await escrow.handlePaymentNotify('wechat', notifyData, rawBody, req.headers);

        if (result.success) {
            res.json({ code: 'SUCCESS', message: '成功' });
        } else {
            console.error('[Webhook] 微信回调处理失败:', result.error);
            res.status(400).json({ code: 'FAIL', message: result.error || '处理失败' });
        }
    } catch (err) {
        console.error('[Webhook] 微信回调异常:', err.message);
        res.status(500).json({ code: 'FAIL', message: err.message });
    }
});

module.exports = router;
