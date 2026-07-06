/**
 * 微信支付 v3 封装
 * 基于 HTTPS API v3 接口，自行实现签名与验签
 * 支持: Native扫码 / H5 / JSAPI / 退款 / 验签
 */
const crypto = require('crypto');
const axios = require('axios');
const config = require('../config');

const BASE_URL = 'https://api.mch.weixin.qq.com';

/**
 * 生成请求签名（v3 API）
 * @param {string} method - HTTP 方法
 * @param {string} url - 请求路径（不含域名）
 * @param {string} timestamp - 时间戳
 * @param {string} nonce - 随机串
 * @param {string} body - 请求体
 * @returns {string} Authorization header
 */
function buildAuthorization(method, url, timestamp, nonce, body) {
    const message = `${method}\n${url}\n${timestamp}\n${nonce}\n${body}\n`;
    const sign = crypto.createSign('RSA-SHA256');
    sign.update(message);
    const signature = sign.sign(config.wechat.privateKey, 'base64');
    return `WECHATPAY2-SHA256-RSA2048 mchid="${config.wechat.mchId}",nonce_str="${nonce}",timestamp="${timestamp}",serial_no="${config.wechat.certSerialNo}",signature="${signature}"`;
}

/**
 * 发送微信支付 v3 请求
 */
async function request(method, path, data = {}) {
    if (!config.wechat.enabled) throw new Error('微信支付未配置');

    const timestamp = Math.floor(Date.now() / 1000).toString();
    const nonce = crypto.randomBytes(16).toString('hex');
    const body = method === 'GET' ? '' : JSON.stringify(data);
    const authorization = buildAuthorization(method, path, timestamp, nonce, body);

    const res = await axios({
        method,
        url: BASE_URL + path,
        data: body || undefined,
        headers: {
            'Authorization': authorization,
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'User-Agent': 'card-app-payment/1.0',
        },
        timeout: 15000,
    });

    return res.data;
}

/**
 * Native 扫码支付（PC 端展示二维码）
 * @param {object} params
 * @returns {Promise<{codeUrl: string}>}
 */
async function createNative({ outTradeNo, totalAmount, description, openid }) {
    const data = await request('POST', '/v3/pay/transactions/native', {
        appid: config.wechat.appId,
        mchid: config.wechat.mchId,
        out_trade_no: outTradeNo,
        description: description,
        notify_url: config.wechat.notifyUrl,
        amount: {
            total: Math.round(totalAmount * 100), // 分
            currency: 'CNY',
        },
    });

    return { codeUrl: data.code_url };
}

/**
 * H5 支付（手机浏览器外跳微信）
 * @param {object} params
 * @returns {Promise<{h5Url: string}>}
 */
async function createH5({ outTradeNo, totalAmount, description, payerClientIp, sceneInfo }) {
    const data = await request('POST', '/v3/pay/transactions/h5', {
        appid: config.wechat.appId,
        mchid: config.wechat.mchId,
        out_trade_no: outTradeNo,
        description: description,
        notify_url: config.wechat.notifyUrl,
        amount: {
            total: Math.round(totalAmount * 100),
            currency: 'CNY',
        },
        scene_info: {
            payer_client_ip: payerClientIp,
            h5_info: {
                type: 'Wap',
                app_name: '卡域',
                app_url: sceneInfo || 'https://kayu.app',
            },
        },
    });

    return { h5Url: data.h5_url };
}

/**
 * JSAPI 支付（微信内公众号/小程序）
 * @param {object} params - 需包含 openid
 */
async function createJsapi({ outTradeNo, totalAmount, description, openid }) {
    if (!openid) throw new Error('JSAPI 支付需要 openid');

    const data = await request('POST', '/v3/pay/transactions/jsapi', {
        appid: config.wechat.appId,
        mchid: config.wechat.mchId,
        out_trade_no: outTradeNo,
        description: description,
        notify_url: config.wechat.notifyUrl,
        amount: {
            total: Math.round(totalAmount * 100),
            currency: 'CNY',
        },
        payer: { openid },
    });

    // 生成前端调起支付的参数
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const nonceStr = crypto.randomBytes(16).toString('hex');
    const packageStr = `prepay_id=${data.prepay_id}`;
    const payMessage = `${config.wechat.appId}\n${timestamp}\n${nonceStr}\n${packageStr}\n`;
    const sign = crypto.createSign('RSA-SHA256');
    sign.update(payMessage);
    const paySign = sign.sign(config.wechat.privateKey, 'base64');

    return {
        jsapiParams: {
            appId: config.wechat.appId,
            timeStamp: timestamp,
            nonceStr,
            package: packageStr,
            signType: 'RSA',
            paySign,
        },
    };
}

/**
 * 统一下单入口
 * @param {object} params - { outTradeNo, totalAmount, description, method, openid, clientIp }
 * @param {string} params.method - 'native' | 'h5' | 'jsapi'
 */
async function createPayment({ outTradeNo, totalAmount, description, method = 'native', openid, clientIp, sceneInfo }) {
    switch (method) {
        case 'h5':
            return createH5({ outTradeNo, totalAmount, description, payerClientIp: clientIp, sceneInfo });
        case 'jsapi':
            return createJsapi({ outTradeNo, totalAmount, description, openid });
        case 'native':
        default:
            return createNative({ outTradeNo, totalAmount, description });
    }
}

/**
 * 验证微信支付回调签名（v3 API）
 * @param {object} headers - 请求头
 * @param {string} rawBody - 原始请求体
 * @returns {boolean}
 */
function verifyNotify(headers, rawBody) {
    try {
        const timestamp = headers['wechatpay-timestamp'];
        const nonce = headers['wechatpay-nonce'];
        const signature = headers['wechatpay-signature'];
        const serial = headers['wechatpay-serial'];

        if (!timestamp || !nonce || !signature) return false;

        const message = `${timestamp}\n${nonce}\n${rawBody}\n`;
        const verify = crypto.createVerify('RSA-SHA256');
        verify.update(message);

        // 使用平台证书验签
        return verify.verify(config.wechat.platformCert, signature, 'base64');
    } catch (err) {
        console.error('[WeChat] 验签失败:', err.message);
        return false;
    }
}

/**
 * 解密回调中的加密数据（AES-256-GCM）
 * @param {string} ciphertext - Base64 密文
 * @param {string} nonce - 附加串
 * @param {string} associatedData - 附加数据
 * @returns {object}
 */
function decryptResource(ciphertext, nonce, associatedData) {
    const key = Buffer.from(config.wechat.apiV3Key, 'utf8');
    const cipherBuf = Buffer.from(ciphertext, 'base64');
    const authTag = cipherBuf.slice(cipherBuf.length - 16);
    const encryptedData = cipherBuf.slice(0, cipherBuf.length - 16);

    const decipher = crypto.createDecipheriv('aes-256-gcm', key, nonce);
    decipher.setAuthTag(authTag);
    decipher.setAAD(Buffer.from(associatedData));

    const decrypted = Buffer.concat([decipher.update(encryptedData), decipher.final()]).toString('utf8');
    return JSON.parse(decrypted);
}

/**
 * 查询订单状态
 * @param {string} outTradeNo - 商户订单号
 */
async function queryTrade(outTradeNo) {
    const path = `/v3/pay/transactions/out-trade-no/${outTradeNo}?mchid=${config.wechat.mchId}`;
    const data = await request('GET', path);

    return {
        tradeStatus: data.trade_state,
        tradeNo: data.transaction_id,
        totalAmount: data.amount ? data.amount.total / 100 : 0,
        buyerLogonId: data.payer ? data.payer.openid : null,
    };
}

/**
 * 退款
 * @param {string} outTradeNo - 商户订单号
 * @param {number} refundAmount - 退款金额（元）
 * @param {string} reason - 退款原因
 */
async function refund(outTradeNo, refundAmount, reason) {
    const refundNo = 'RFD' + Date.now() + Math.floor(Math.random() * 1000);
    const data = await request('POST', '/v3/refund/domestic/refunds', {
        out_trade_no: outTradeNo,
        out_refund_no: refundNo,
        reason: reason || '用户退款',
        amount: {
            refund: Math.round(refundAmount * 100),
            total: Math.round(refundAmount * 100),
            currency: 'CNY',
        },
    });

    if (data.status === 'SUCCESS' || data.status === 'PROCESSING') {
        return { success: true, tradeNo: data.transaction_id, refundNo };
    }
    throw new Error('微信退款失败: ' + (data.status || '未知错误'));
}

module.exports = {
    createPayment,
    createNative,
    createH5,
    createJsapi,
    verifyNotify,
    decryptResource,
    queryTrade,
    refund,
};
