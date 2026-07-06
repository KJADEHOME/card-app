/**
 * 支付宝支付封装
 * 基于 alipay-sdk 官方 SDK
 * 支持: PC网站支付 / 手机网站支付 / 当面付(扫码) / 退款 / 验签
 */
const AlipaySdk = require('alipay-sdk').default;
const crypto = require('crypto');
const config = require('../config');

let sdk = null;

/**
 * 初始化支付宝 SDK（懒加载，未配置时返回 null）
 */
function getSdk() {
    if (!config.alipay.enabled) return null;
    if (sdk) return sdk;

    sdk = new AlipaySdk({
        appId: config.alipay.appId,
        privateKey: config.alipay.appPrivateKey,
        alipayPublicKey: config.alipay.alipayPublicKey,
        signType: config.alipay.signType,
        gateway: config.alipay.gateway,
    });
    return sdk;
}

/**
 * 创建 PC 网站支付（电脑端跳转支付宝页面）
 * @param {string} outTradeNo - 商户订单号
 * @param {number} totalAmount - 金额（元）
 * @param {string} subject - 订单标题
 * @returns {Promise<{payUrl: string}>}
 */
async function createPagePay(outTradeNo, totalAmount, subject) {
    const alipay = getSdk();
    if (!alipay) throw new Error('支付宝未配置');

    const result = await alipay.pageExec('alipay.trade.page.pay', {
        method: 'GET',
        bizContent: {
            out_trade_no: outTradeNo,
            total_amount: totalAmount.toFixed(2),
            subject: subject,
            product_code: 'FAST_INSTANT_TRADE_PAY',
        },
        notify_url: config.alipay.notifyUrl,
        return_url: config.alipay.returnUrl,
    });

    return { payUrl: result };
}

/**
 * 创建手机网站支付（H5 跳转支付宝 APP）
 */
async function createWapPay(outTradeNo, totalAmount, subject) {
    const alipay = getSdk();
    if (!alipay) throw new Error('支付宝未配置');

    const result = await alipay.pageExec('alipay.trade.wap.pay', {
        method: 'GET',
        bizContent: {
            out_trade_no: outTradeNo,
            total_amount: totalAmount.toFixed(2),
            subject: subject,
            product_code: 'QUICK_WAP_WAY',
        },
        notify_url: config.alipay.notifyUrl,
        return_url: config.alipay.returnUrl,
    });

    return { payUrl: result };
}

/**
 * 创建当面付（扫码支付，返回二维码链接）
 * @returns {Promise<{qrCode: string}>}
 */
async function createPrecreate(outTradeNo, totalAmount, subject) {
    const alipay = getSdk();
    if (!alipay) throw new Error('支付宝未配置');

    const result = await alipay.exec('alipay.trade.precreate', {
        bizContent: {
            out_trade_no: outTradeNo,
            total_amount: totalAmount.toFixed(2),
            subject: subject,
        },
        notify_url: config.alipay.notifyUrl,
    });

    if (result.qrCode) {
        return { qrCode: result.qrCode };
    }
    throw new Error('支付宝预下单失败: ' + JSON.stringify(result));
}

/**
 * 统一下单入口 - 根据场景自动选择支付方式
 * @param {object} params - { outTradeNo, totalAmount, subject, method }
 * @param {string} params.method - 'page' | 'wap' | 'qr'
 */
async function createPayment({ outTradeNo, totalAmount, subject, method = 'page' }) {
    switch (method) {
        case 'wap':
            return createWapPay(outTradeNo, totalAmount, subject);
        case 'qr':
            return createPrecreate(outTradeNo, totalAmount, subject);
        case 'page':
        default:
            return createPagePay(outTradeNo, totalAmount, subject);
    }
}

/**
 * 验证支付宝异步通知签名
 * @param {object} postData - 支付宝 POST 过来的表单数据
 * @returns {boolean}
 */
function verifyNotify(postData) {
    const alipay = getSdk();
    if (!alipay) return false;

    try {
        // alipay-sdk v4 提供验签方法
        const signVerified = alipay.checkNotifySign(postData);
        return signVerified;
    } catch (err) {
        console.error('[Alipay] 验签失败:', err.message);
        return false;
    }
}

/**
 * 查询交易状态
 * @param {string} outTradeNo - 商户订单号
 */
async function queryTrade(outTradeNo) {
    const alipay = getSdk();
    if (!alipay) throw new Error('支付宝未配置');

    const result = await alipay.exec('alipay.trade.query', {
        bizContent: { out_trade_no: outTradeNo },
    });

    return {
        tradeStatus: result.tradeStatus || result.trade_status,
        tradeNo: result.tradeNo || result.trade_no,
        totalAmount: parseFloat(result.totalAmount || result.total_amount || '0'),
        buyerLogonId: result.buyerLogonId || result.buyer_logon_id,
    };
}

/**
 * 退款
 * @param {string} outTradeNo - 商户订单号
 * @param {number} refundAmount - 退款金额
 * @param {string} refundReason - 退款原因
 */
async function refund(outTradeNo, refundAmount, refundReason) {
    const alipay = getSdk();
    if (!alipay) throw new Error('支付宝未配置');

    const result = await alipay.exec('alipay.trade.refund', {
        bizContent: {
            out_trade_no: outTradeNo,
            refund_amount: refundAmount.toFixed(2),
            refund_reason: refundReason || '用户退款',
        },
    });

    if (result.code === '10000' || result.fundChange === 'Y') {
        return { success: true, tradeNo: result.tradeNo || result.trade_no };
    }
    throw new Error('支付宝退款失败: ' + (result.subMsg || result.sub_msg || '未知错误'));
}

module.exports = {
    getSdk,
    createPayment,
    createPagePay,
    createWapPay,
    createPrecreate,
    verifyNotify,
    queryTrade,
    refund,
};
