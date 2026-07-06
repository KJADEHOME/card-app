/**
 * 卡域支付客户端 SDK
 * 封装与支付服务端 API 的交互，供所有页面调用
 *
 * 依赖: 全局 db (supabase client), supabase (CDN)
 * 用法:
 *   PaymentClient.startRecharge(100, 'alipay')
 *   PaymentClient.startOrderPayment(orderId, 'wechat')
 *   PaymentClient.payWithBalance(orderId)
 *   PaymentClient.confirmReceipt(orderId)
 */
const PaymentClient = {
    // 支付服务地址（部署时改为实际域名）
    baseUrl: window.PAYMENT_SERVER_URL || 'http://localhost:3001',

    /**
     * 获取当前用户 access token
     */
    async getToken() {
        if (typeof db === 'undefined') throw new Error('Supabase 未初始化');
        const { data: { session } } = await db.auth.getSession();
        if (!session) throw new Error('请先登录');
        return session.access_token;
    },

    /**
     * 统一请求封装
     */
    async request(path, options = {}) {
        const token = await this.getToken();
        const res = await fetch(this.baseUrl + path, {
            ...options,
            headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ' + token,
                ...(options.headers || {}),
            },
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || '请求失败 (' + res.status + ')');
        return data;
    },

    /**
     * 创建支付（充值或订单付款）
     * @param {object} params
     * @param {string} params.provider - 'alipay' | 'wechat'
     * @param {string} params.businessType - 'recharge' | 'order'
     * @param {string} [params.businessId] - 订单ID（order 类型必填）
     * @param {number} [params.amount] - 金额（recharge 必填）
     * @param {string} [params.subject] - 标题
     * @param {string} [params.openid] - 微信 openid（JSAPI 必填）
     */
    async createPayment(params) {
        return this.request('/api/payment/create', {
            method: 'POST',
            body: JSON.stringify(params),
        });
    },

    /**
     * 查询支付状态
     */
    async queryStatus(paymentNo) {
        return this.request('/api/payment/status/' + paymentNo);
    },

    /**
     * 余额支付订单
     */
    async payWithBalance(orderId) {
        return this.request('/api/payment/balance', {
            method: 'POST',
            body: JSON.stringify({ orderId }),
        });
    },

    /**
     * 确认收货（释放资金给卖家）
     */
    async confirmReceipt(orderId) {
        return this.request('/api/escrow/confirm/' + orderId, { method: 'POST' });
    },

    /**
     * 退款
     */
    async refund(orderId, reason) {
        return this.request('/api/escrow/refund/' + orderId, {
            method: 'POST',
            body: JSON.stringify({ reason }),
        });
    },

    /**
     * 查询托管记录
     */
    async getEscrowRecord(orderId) {
        return this.request('/api/escrow/record/' + orderId);
    },

    /**
     * 轮询支付状态（支付成功时 resolve，失败/超时 reject）
     * @param {string} paymentNo
     * @param {number} timeout - 超时毫秒（默认 5 分钟）
     * @param {number} interval - 轮询间隔（默认 2 秒）
     */
    pollPaymentStatus(paymentNo, timeout = 300000, interval = 2000) {
        return new Promise((resolve, reject) => {
            const startTime = Date.now();
            const timer = setInterval(async () => {
                if (Date.now() - startTime > timeout) {
                    clearInterval(timer);
                    reject(new Error('支付超时'));
                    return;
                }
                try {
                    const status = await this.queryStatus(paymentNo);
                    if (status.status === 'paid') {
                        clearInterval(timer);
                        resolve(status);
                    } else if (status.status === 'failed' || status.status === 'closed') {
                        clearInterval(timer);
                        reject(new Error('支付失败: ' + status.status));
                    }
                } catch (err) {
                    console.warn('[Payment] 轮询状态失败:', err.message);
                }
            }, interval);
        });
    },

    /**
     * 发起充值（完整流程）
     * @param {number} amount - 金额（元）
     * @param {string} provider - 'alipay' | 'wechat'
     * @returns {Promise<object>} { type: 'qrcode'|'redirect'|'jsapi', ... }
     */
    async startRecharge(amount, provider = 'alipay') {
        const result = await this.createPayment({
            provider,
            businessType: 'recharge',
            amount,
            subject: '卡域钱包充值 ' + amount + '元',
        });

        // 跳转支付（H5 / PC 网页支付）
        if (result.pay_url) {
            return { type: 'redirect', url: result.pay_url, paymentNo: result.payment_no };
        }
        // 扫码支付
        if (result.qrcode) {
            return { type: 'qrcode', qrcode: result.qrcode, paymentNo: result.payment_no, amount: result.amount };
        }
        // 微信 JSAPI
        if (result.jsapi_params) {
            return { type: 'jsapi', params: result.jsapi_params, paymentNo: result.payment_no };
        }
        return result;
    },

    /**
     * 发起订单支付（完整流程）
     * @param {string} orderId - 订单 ID
     * @param {string} provider - 'alipay' | 'wechat'
     */
    async startOrderPayment(orderId, provider = 'alipay') {
        const result = await this.createPayment({
            provider,
            businessType: 'order',
            businessId: orderId,
        });

        if (result.pay_url) {
            return { type: 'redirect', url: result.pay_url, paymentNo: result.payment_no };
        }
        if (result.qrcode) {
            return { type: 'qrcode', qrcode: result.qrcode, paymentNo: result.payment_no, amount: result.amount };
        }
        if (result.jsapi_params) {
            return { type: 'jsapi', params: result.jsapi_params, paymentNo: result.payment_no };
        }
        return result;
    },

    /**
     * 调起微信 JSAPI 支付（微信浏览器内）
     */
    callWechatJsapi(params) {
        if (typeof WeixinJSBridge === 'undefined') {
            throw new Error('请在微信内打开页面进行支付');
        }
        return new Promise((resolve, reject) => {
            WeixinJSBridge.invoke('getBrandWCPayRequest', params, (res) => {
                if (res.err_msg === 'get_brand_wcpay_request:ok') {
                    resolve(res);
                } else {
                    reject(new Error('微信支付失败: ' + res.err_msg));
                }
            });
        });
    },
};

window.PaymentClient = PaymentClient;
