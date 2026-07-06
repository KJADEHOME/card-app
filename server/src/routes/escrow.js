/**
 * 资金担保操作路由
 *   POST /api/escrow/confirm/:orderId    - 买家确认收货（释放资金给卖家）
 *   POST /api/escrow/refund/:orderId     - 退款（资金退回买家）
 *   GET  /api/escrow/record/:orderId     - 查询托管记录
 *   POST /api/escrow/auto-confirm        - 触发超时自动确认（定时任务/管理员）
 */
const express = require('express');
const router = express.Router();
const escrow = require('../lib/escrow');
const { authMiddleware, serviceClient } = require('../middleware/auth');

/**
 * 买家确认收货 - 释放托管资金给卖家
 */
router.post('/confirm/:orderId', authMiddleware, async (req, res) => {
    try {
        const result = await escrow.releaseToSeller(req.params.orderId, req.accessToken);
        res.json(result);
    } catch (err) {
        console.error('[Escrow] 确认收货失败:', err.message);
        res.status(500).json({ error: err.message });
    }
});

/**
 * 退款 - 资金退回买家
 * body: { reason }
 */
router.post('/refund/:orderId', authMiddleware, async (req, res) => {
    try {
        const { reason } = req.body;
        const result = await escrow.refundToBuyer(
            req.params.orderId,
            reason || '协商退款',
            req.accessToken
        );
        res.json(result);
    } catch (err) {
        console.error('[Escrow] 退款失败:', err.message);
        res.status(500).json({ error: err.message });
    }
});

/**
 * 查询订单的托管记录（仅买家/卖家可查）
 */
router.get('/record/:orderId', authMiddleware, async (req, res) => {
    try {
        const { data, error } = await serviceClient
            .from('escrow_records')
            .select('*')
            .eq('order_id', req.params.orderId)
            .single();

        if (error) throw new Error(error.message);
        if (!data) return res.status(404).json({ error: '托管记录不存在' });

        // 权限校验
        if (data.buyer_id !== req.user.id && data.seller_id !== req.user.id) {
            return res.status(403).json({ error: '无权查看此托管记录' });
        }

        res.json(data);
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

/**
 * 触发超时自动确认（定时任务或管理员手动调用）
 */
router.post('/auto-confirm', authMiddleware, async (req, res) => {
    try {
        const result = await escrow.autoConfirmOrders();
        res.json(result);
    } catch (err) {
        console.error('[Escrow] 自动确认失败:', err.message);
        res.status(500).json({ error: err.message });
    }
});

module.exports = router;
