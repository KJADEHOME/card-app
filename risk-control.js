/**
 * risk-control.js — CardRealm 风控前端中间件
 * 功能:
 *   1. 客户端频率限制（防按钮连点）
 *   2. 请求签名（timestamp + nonce）
 *   3. 风控状态展示（今日AI次数/成本/交易数）
 *   4. 防重复提交（debounce + lock）
 */

// ============================================================
// 1. 客户端频率限制器
// ============================================================
const RateLimiter = {
    _locks: new Map(), // key -> unlock timestamp

    /**
     * 检查是否被限频
     * @param {string} action - 动作名称 (e.g. 'ai_scan', 'buy', 'signin')
     * @param {number} cooldownMs - 冷却时间(毫秒)
     * @returns {boolean} true=可以执行, false=被限频
     */
    canDo(action, cooldownMs = 3000) {
        const now = Date.now();
        const unlockAt = this._locks.get(action) || 0;
        if (now < unlockAt) return false;
        this._locks.set(action, now + cooldownMs);
        return true;
    },

    /**
     * 获取剩余冷却时间
     */
    remainingCooldown(action) {
        const now = Date.now();
        const unlockAt = this._locks.get(action) || 0;
        return Math.max(0, Math.ceil((unlockAt - now) / 1000));
    },

    /**
     * 重置某个动作的冷却
     */
    reset(action) {
        this._locks.delete(action);
    }
};

// ============================================================
// 2. 请求签名工具
// ============================================================
const RequestSigner = {
    /**
     * 生成带timestamp的请求头
     * 服务端校验timestamp必须在60秒内
     */
    getSignedHeaders(userId) {
        return {
            'X-User-Id': userId || '',
            'X-Timestamp': String(Math.floor(Date.now() / 1000)),
            'X-Client-IP': '', // 服务端自动获取
        };
    }
};

// ============================================================
// 3. 防重复提交锁
// ============================================================
const SubmitLock = {
    _locked: new Set(),

    /**
     * 获取锁（防重复提交）
     * @param {string} key - 唯一标识 (e.g. `buy_${consignmentId}`)
     * @returns {boolean} true=获取成功, false=已被锁
     */
    acquire(key) {
        if (this._locked.has(key)) return false;
        this._locked.add(key);
        return true;
    },

    /**
     * 释放锁
     */
    release(key) {
        this._locked.delete(key);
    },

    /**
     * 带锁执行函数
     */
    async withLock(key, fn) {
        if (!this.acquire(key)) {
            console.warn(`[SubmitLock] Action "${key}" is already in progress`);
            return null;
        }
        try {
            return await fn();
        } finally {
            this.release(key);
        }
    }
};

// ============================================================
// 4. 风控状态展示
// ============================================================
const RiskStatus = {
    /**
     * 加载用户风控状态
     */
    async load(supabaseClient, userId) {
        try {
            const { data, error } = await supabaseClient
                .rpc('get_user_risk_status', { p_user_id: userId });

            if (error || !data) return null;
            return data;
        } catch (e) {
            console.warn('[RiskStatus] load error:', e);
            return null;
        }
    },

    /**
     * 根据风控等级获取状态文本
     */
    getLevelText(level) {
        const map = {
            0: { text: '正常', color: '#27AE60', icon: '✅' },
            1: { text: '高频', color: '#F39C12', icon: '⚠️' },
            2: { text: '风险', color: '#E74C3C', icon: '🚫' },
            3: { text: '封禁', color: '#C0392B', icon: '⛔' }
        };
        return map[level] || map[0];
    },

    /**
     * 渲染风控状态卡片（可在collection.html / dashboard.html中调用）
     */
    render(containerId, status) {
        const el = document.getElementById(containerId);
        if (!el || !status) return;

        const levelInfo = this.getLevelText(status.risk_level);
        const scanLimit = 10; // daily AI scan limit

        el.innerHTML = `
            <div style="background:#f8f9fa;border-radius:12px;padding:14px;margin:10px 0;">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px;">
                    <span style="font-weight:600;font-size:14px;">🛡️ 账号状态</span>
                    <span style="color:${levelInfo.color};font-weight:600;font-size:13px;">
                        ${levelInfo.icon} ${levelInfo.text}
                    </span>
                </div>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;font-size:12px;color:#666;">
                    <div>
                        <div style="color:#999;">今日识卡</div>
                        <div style="font-weight:600;color:#333;">${status.today_scans}/${scanLimit}</div>
                    </div>
                    <div>
                        <div style="color:#999;">今日交易</div>
                        <div style="font-weight:600;color:#333;">${status.today_trades}</div>
                    </div>
                    <div>
                        <div style="color:#999;">今日积分</div>
                        <div style="font-weight:600;color:#333;">+${status.today_points}</div>
                    </div>
                </div>
                ${status.risk_level >= 2 ? `
                    <div style="margin-top:10px;padding:8px 12px;background:#FFF3CD;border-radius:8px;font-size:12px;color:#856404;">
                        ⚠️ 账号存在异常行为，部分功能可能受限
                        ${status.restricted_until ? `<br>限制至: ${new Date(status.restricted_until).toLocaleString()}` : ''}
                    </div>
                ` : ''}
            </div>
        `;
    }
};

// ============================================================
// 5. 便捷方法: 带风控检查的AI识卡请求
// ============================================================

/**
 * 调用AI识卡（带频率限制 + 防重复提交）
 * @param {string} base64Image - base64编码的图片
 * @param {string} userId - 用户ID
 * @param {object} supabaseConfig - {url, anonKey}
 * @returns {Promise<object>} 识别结果
 */
async function safeAIScan(base64Image, userId, supabaseConfig) {
    // 1. 客户端频率限制（3秒冷却）
    if (!RateLimiter.canDo('ai_scan', 3000)) {
        const remain = RateLimiter.remainingCooldown('ai_scan');
        throw new Error(`请求过于频繁，请等待${remain}秒`);
    }

    // 2. 防重复提交
    return await SubmitLock.withLock('ai_scan_request', async () => {
        const headers = {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + supabaseConfig.anonKey,
            'apikey': supabaseConfig.anonKey,
            ...RequestSigner.getSignedHeaders(userId)
        };

        const response = await fetch(supabaseConfig.url + '/functions/v1/ai-scan', {
            method: 'POST',
            headers: headers,
            body: JSON.stringify({ image: base64Image })
        });

        const result = await response.json();

        // 处理限频响应
        if (response.status === 429) {
            if (result.cooldown_remaining) {
                throw new Error(`请求过于频繁，请等待${result.cooldown_remaining}秒`);
            }
            if (result.budget_exceeded) {
                throw new Error('今日AI识别次数已达上限，请明天再来');
            }
            throw new Error(result.error || '请求过于频繁');
        }

        if (response.status === 403 && result.risk_blocked) {
            throw new Error(result.error || '账号已被限制使用AI识卡');
        }

        if (!response.ok || result.error) {
            throw new Error(result.error || 'AI识别失败');
        }

        return result.data;
    });
}

/**
 * 安全购买（带防重复提交 + 幂等键）
 * @param {object} supabaseClient - Supabase客户端
 * @param {string} buyerId - 买家ID
 * @param {string} consignmentId - 寄售单ID
 * @returns {Promise<object>} 交易结果
 */
async function safePurchase(supabaseClient, buyerId, consignmentId) {
    // 1. 客户端频率限制（5秒冷却）
    if (!RateLimiter.canDo('purchase_' + consignmentId, 5000)) {
        throw new Error('正在处理中，请勿重复点击');
    }

    // 2. 防重复提交 + 幂等键
    const idempotencyKey = `buy_${buyerId}_${consignmentId}_${Date.now()}`;

    return await SubmitLock.withLock('purchase_' + consignmentId, async () => {
        const { data, error } = await supabaseClient.rpc('purchase_consignment_safe', {
            p_buyer_id: buyerId,
            p_consignment_id: consignmentId,
            p_idempotency_key: idempotencyKey,
            p_ip_address: null
        });

        if (error) throw new Error(error.message);
        if (!data.success) throw new Error(data.error);

        return data;
    });
}

// ============================================================
// 导出（兼容浏览器全局和模块）
// ============================================================
if (typeof window !== 'undefined') {
    window.RateLimiter = RateLimiter;
    window.RequestSigner = RequestSigner;
    window.SubmitLock = SubmitLock;
    window.RiskStatus = RiskStatus;
    window.safeAIScan = safeAIScan;
    window.safePurchase = safePurchase;
}
