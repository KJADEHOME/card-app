/**
 * 资金担保监管核心逻辑
 * 协调 Supabase RPC 与第三方支付，保证资金流转一致性
 *
 * 核心流程:
 *   1. createEscrowPayment  - 创建支付（支付宝/微信下单）
 *   2. handlePaymentNotify  - 处理支付回调（冻结资金）
 *   3. releaseToSeller      - 确认收货（释放资金给卖家）
 *   4. refundToBuyer        - 退款（资金退回买家）
 *   5. autoConfirmOrders    - 超时自动确认
 */
const supabase = require('../db');
const config = require('../config');
const alipay = require('./alipay');
const wechat = require('./wechat');
const QRCode = require('qrcode');

/**
 * 检测客户端类型，返回合适的支付方式
 * @param {string} userAgent
 * @returns {object} { alipayMethod, wechatMethod, isMobile, isWechatBrowser }
 */
function detectClient(userAgent) {
    const ua = (userAgent || '').toLowerCase();
    const isMobile = /android|iphone|ipad|ipod|mobile/i.test(ua);
    const isWechatBrowser = /micromessenger/i.test(ua);

    return {
        isMobile,
        isWechatBrowser,
        // 支付宝: 手机用 wap, PC 用 page(跳转), 扫码用 qr
        alipayMethod: isMobile ? 'wap' : 'page',
        // 微信: 微信浏览器内用 jsapi, 手机用 h5, PC 用 native(扫码)
        wechatMethod: isWechatBrowser ? 'jsapi' : (isMobile ? 'h5' : 'native'),
    };
}

/**
 * 创建支付（统一下单）
 * 1. 在 DB 创建支付订单（RPC create_payment_order）
 * 2. 调用第三方支付下单
 * 3. 返回支付参数给前端
 *
 * @param {object} params
 * @param {string} params.provider - 'alipay' | 'wechat'
 * @param {string} params.businessType - 'order' | 'recharge'
 * @param {string} params.businessId - 订单ID（order 类型必填）
 * @param {number} params.amount - 金额（recharge 必填）
 * @param {string} params.subject - 标题
 * @param {string} params.userAgent - UA
 * @param {string} params.openid - 微信 openid（jsapi 必填）
 * @param {string} params.clientIp - 客户端 IP
 * @returns {Promise<object>}
 */
async function createEscrowPayment(params) {
    const { provider, businessType, businessId, amount, subject, userAgent, openid, clientIp } = params;

    if (!['alipay', 'wechat'].includes(provider)) {
        throw new Error('不支持的支付方式: ' + provider);
    }

    // 1. DB 创建支付订单
    const { data: payOrder, error: rpcError } = await supabase.rpc('create_payment_order', {
        p_business_type: businessType,
        p_business_id: businessId || null,
        p_provider: provider,
        p_amount: amount || 0,
        p_subject: subject || '',
    });

    if (rpcError) throw new Error('创建支付订单失败: ' + rpcError.message);
    if (!payOrder.success) throw new Error(payOrder.error);

    const { payment_no, amount: payAmount, subject: paySubject } = payOrder;

    // 2. 调用第三方支付下单
    const client = detectClient(userAgent);
    let payResult;

    if (provider === 'alipay') {
        payResult = await alipay.createPayment({
            outTradeNo: payment_no,
            totalAmount: parseFloat(payAmount),
            subject: paySubject,
            method: client.alipayMethod,
        });
    } else {
        // 微信
        if (client.wechatMethod === 'jsapi' && !openid) {
            throw new Error('微信内支付需要先获取 openid');
        }
        payResult = await wechat.createPayment({
            outTradeNo: payment_no,
            totalAmount: parseFloat(payAmount),
            description: paySubject,
            method: client.wechatMethod,
            openid,
            clientIp: clientIp || '127.0.0.1',
        });
    }

    // 3. 如果是扫码支付，生成二维码图片 DataURL
    let qrcodeDataUrl = null;
    if (payResult.qrCode) {
        qrcodeDataUrl = await QRCode.toDataURL(payResult.qrCode, { width: 280, margin: 1 });
    } else if (payResult.codeUrl) {
        qrcodeDataUrl = await QRCode.toDataURL(payResult.codeUrl, { width: 280, margin: 1 });
    }

    // 4. 更新支付订单的支付链接
    await supabase
        .from('payment_orders')
        .update({
            pay_url: payResult.payUrl || payResult.h5Url || null,
            qrcode_url: payResult.qrCode || payResult.codeUrl || null,
        })
        .eq('payment_no', payment_no);

    return {
        success: true,
        payment_no: payment_no,
        amount: payAmount,
        provider,
        method: provider === 'alipay' ? client.alipayMethod : client.wechatMethod,
        pay_url: payResult.payUrl || payResult.h5Url || null,
        qrcode: qrcodeDataUrl,
        jsapi_params: payResult.jsapiParams || null,
    };
}

/**
 * 处理支付回调（支付宝/微信通用）
 * 1. 验签
 * 2. 调用 DB RPC process_payment_success 冻结资金
 *
 * @param {string} provider - 'alipay' | 'wechat'
 * @param {object} notifyData - 解析后的通知数据
 * @param {string} rawBody - 原始请求体（微信验签用）
 * @param {object} headers - 请求头（微信验签用）
 * @returns {Promise<object>}
 */
async function handlePaymentNotify(provider, notifyData, rawBody, headers) {
    // 1. 验签
    let verified = false;
    if (provider === 'alipay') {
        verified = alipay.verifyNotify(notifyData);
    } else {
        verified = wechat.verifyNotify(headers, rawBody);
        // 微信需要解密 resource
        if (verified && notifyData.resource) {
            const decrypted = wechat.decryptResource(
                notifyData.resource.ciphertext,
                notifyData.resource.nonce,
                notifyData.resource.associated_data
            );
            notifyData = { ...notifyData, ...decrypted };
        }
    }

    if (!verified) {
        return { success: false, error: '验签失败' };
    }

    // 2. 提取关键字段
    let paymentNo, tradeNo;
    if (provider === 'alipay') {
        // 支付宝: TRADE_SUCCESS 才算成功
        if (notifyData.trade_status !== 'TRADE_SUCCESS' && notifyData.trade_status !== 'TRADE_FINISHED') {
            return { success: true, skipped: true, message: '非成功状态，跳过' };
        }
        paymentNo = notifyData.out_trade_no;
        tradeNo = notifyData.trade_no;
    } else {
        // 微信: event_type = TRANSACTION.SUCCESS
        if (notifyData.event_type !== 'TRANSACTION.SUCCESS' && notifyData.trade_state !== 'SUCCESS') {
            return { success: true, skipped: true, message: '非成功状态，跳过' };
        }
        paymentNo = notifyData.out_trade_no;
        tradeNo = notifyData.transaction_id;
    }

    if (!paymentNo) {
        return { success: false, error: '缺少订单号' };
    }

    // 3. 调用 DB RPC 处理支付成功（冻结资金 / 充值入账）
    const { data: result, error } = await supabase.rpc('process_payment_success', {
        p_payment_no: paymentNo,
        p_trade_no: tradeNo,
        p_provider: provider,
        p_callback_raw: notifyData,
    });

    if (error) {
        console.error('[Escrow] RPC 调用失败:', error.message);
        return { success: false, error: '数据库处理失败: ' + error.message };
    }

    return result;
}

/**
 * 确认收货 - 释放资金给卖家
 * 调用 DB RPC escrow_release_to_seller
 *
 * @param {string} orderId - 订单 ID
 * @param {string} buyerAccessToken - 买家的 Supabase access token（用于 RLS 鉴权）
 */
async function releaseToSeller(orderId, buyerAccessToken) {
    // 使用买家 token 调用 RPC（满足 RLS 权限校验）
    const { createClient } = require('@supabase/supabase-js');
    const userClient = createClient(config.supabase.url, config.supabase.serviceKey, {
        global: { headers: { Authorization: `Bearer ${buyerAccessToken}` } },
    });

    const { data, error } = await userClient.rpc('escrow_release_to_seller', {
        p_order_id: orderId,
    });

    if (error) throw new Error('确认收货失败: ' + error.message);
    return data;
}

/**
 * 退款 - 资金退回买家
 * 1. 调用 DB RPC escrow_refund_to_buyer 更新钱包和订单
 * 2. 如果是第三方支付，调用退款 API
 *
 * @param {string} orderId
 * @param {string} reason
 * @param {string} operatorToken - 操作者 token
 */
async function refundToBuyer(orderId, reason, operatorToken) {
    // 1. 查询托管记录，确定支付方式和金额
    const { data: escrow, error: queryError } = await supabase
        .from('escrow_records')
        .select('*')
        .eq('order_id', orderId)
        .single();

    if (queryError || !escrow) {
        throw new Error('托管记录不存在');
    }

    if (escrow.status !== 'frozen') {
        throw new Error('资金已处理，无法退款: ' + escrow.status);
    }

    // 2. 调用 DB RPC 退款（更新钱包余额和订单状态）
    const { createClient } = require('@supabase/supabase-js');
    const userClient = createClient(config.supabase.url, config.supabase.serviceKey, {
        global: { headers: { Authorization: `Bearer ${operatorToken}` } },
    });

    const { data: refundResult, error: rpcError } = await userClient.rpc('escrow_refund_to_buyer', {
        p_order_id: orderId,
        p_reason: reason,
    });

    if (rpcError) throw new Error('退款 RPC 失败: ' + rpcError.message);
    if (!refundResult.success) throw new Error(refundResult.error);

    // 3. 如果是第三方支付，调用实际退款 API（退到用户原支付账户）
    if (escrow.payment_provider === 'alipay') {
        try {
            await alipay.refund(escrow.payment_order_id ? (await getPaymentNo(escrow.payment_order_id)) : null, parseFloat(escrow.total_amount), reason);
        } catch (err) {
            console.error('[Escrow] 支付宝退款API失败（钱包已退，需人工处理）:', err.message);
        }
    } else if (escrow.payment_provider === 'wechat') {
        try {
            const payNo = await getPaymentNo(escrow.payment_order_id);
            await wechat.refund(payNo, parseFloat(escrow.total_amount), reason);
        } catch (err) {
            console.error('[Escrow] 微信退款API失败（钱包已退，需人工处理）:', err.message);
        }
    }

    return refundResult;
}

/**
 * 根据 payment_order_id 查 payment_no
 */
async function getPaymentNo(paymentOrderId) {
    const { data } = await supabase
        .from('payment_orders')
        .select('payment_no')
        .eq('id', paymentOrderId)
        .single();
    return data?.payment_no;
}

/**
 * 超时自动确认收货（定时任务）
 * 调用 DB RPC escrow_auto_confirm
 */
async function autoConfirmOrders() {
    const { data, error } = await supabase.rpc('escrow_auto_confirm');

    if (error) {
        console.error('[Escrow] 自动确认失败:', error.message);
        return { success: false, error: error.message };
    }

    return data;
}

/**
 * 查询支付订单状态（前端轮询用）
 * @param {string} paymentNo
 */
async function queryPaymentStatus(paymentNo) {
    const { data, error } = await supabase
        .from('payment_orders')
        .select('payment_no, status, amount, provider, business_type, business_id, paid_at, trade_no')
        .eq('payment_no', paymentNo)
        .single();

    if (error) throw new Error('查询失败: ' + error.message);
    return data;
}

module.exports = {
    detectClient,
    createEscrowPayment,
    handlePaymentNotify,
    releaseToSeller,
    refundToBuyer,
    autoConfirmOrders,
    queryPaymentStatus,
};
