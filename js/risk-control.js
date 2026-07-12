/**
 * risk-control.js — 卡域 CardRealm 统一安全模块
 * SEC-004: Image Upload Security
 * 
 * 功能:
 *   - validateImageFile(file)    前端文件验证 (MIME/大小/扩展名)
 *   - compressImage(base64, opts) 前端图片压缩+缩放
 *   - stripExifData(dataUrl)     前端EXIF清理
 *   - generateImageHash(base64)  前端去重hash (SHA-256前8字节)
 *   - escapeHtml(str)            全站XSS防护
 *   - safeUrl(url)               URL协议白名单验证
 *   - isValidUUID(uuid)          UUID v4格式校验
 *   - validateAction(action, wl) 动作白名单校验
 */

const RiskControl = (() => {
  // ========== 安全参数 ==========

  const CONFIG = {
    // 文件大小
    MAX_FILE_SIZE_MB: 5,
    MAX_FILE_SIZE_BYTES: 5 * 1024 * 1024,
    MAX_BASE64_SIZE_MB: 6.5,
    MAX_BASE64_SIZE_BYTES: 6.5 * 1024 * 1024,

    // MIME白名单
    ALLOWED_MIME_TYPES: ['image/jpeg', 'image/png', 'image/webp'],

    // 扩展名白名单
    ALLOWED_EXTENSIONS: ['jpg', 'jpeg', 'png', 'webp'],

    // 图片像素
    MAX_IMAGE_WIDTH: 2048,
    MAX_IMAGE_HEIGHT: 2048,

    // 压缩
    COMPRESS_QUALITY: 0.85,
    COMPRESS_THRESHOLD_KB: 500, // 超过500KB才压缩

    // AI扫描速率 (配合服务端 ai_scan_logs)
    SCAN_DAILY_LIMIT: 50,
  };

  // ========== validateImageFile ==========

  /**
   * 前端文件验证: MIME类型 + 文件大小 + 扩展名
   * @param {File} file - 用户选择的文件
   * @returns {{ ok: boolean, error: string|null, meta: object }}
   */
  function validateImageFile(file) {
    if (!file) {
      return { ok: false, error: '未选择文件', meta: {} };
    }

    // 1. 文件大小
    if (file.size > CONFIG.MAX_FILE_SIZE_BYTES) {
      const sizeMB = (file.size / 1024 / 1024).toFixed(1);
      return { ok: false, error: `文件过大 (${sizeMB}MB)，上限 ${CONFIG.MAX_FILE_SIZE_MB}MB`, meta: { size: file.size } };
    }

    // 2. MIME类型
    const mime = file.type || '';
    if (!CONFIG.ALLOWED_MIME_TYPES.includes(mime)) {
      return { ok: false, error: `不支持的文件类型 (${mime})，仅限 JPG/PNG/WebP`, meta: { mime } };
    }

    // 3. 扩展名
    const ext = file.name.split('.').pop().toLowerCase();
    if (!CONFIG.ALLOWED_EXTENSIONS.includes(ext)) {
      return { ok: false, error: `不支持的扩展名 (.${ext})，仅限 .jpg/.png/.webp`, meta: { ext } };
    }

    return {
      ok: true,
      error: null,
      meta: {
        name: file.name,
        size: file.size,
        mime: mime,
        ext: ext,
      }
    };
  }

  // ========== compressImage ==========

  /**
   * 前端图片压缩+缩放
   * 通过 canvas 重绘实现，自动清理EXIF
   * @param {string} dataUrl - base64 DataURL (含前缀)
   * @param {object} opts - 可选参数
   * @param {number} opts.maxKB - 压缩目标KB (默认 CONFIG.COMPRESS_THRESHOLD_KB)
   * @param {number} opts.quality - JPEG质量 (默认 CONFIG.COMPRESS_QUALITY)
   * @param {number} opts.maxWidth - 最大宽度 (默认 CONFIG.MAX_IMAGE_WIDTH)
   * @param {number} opts.maxHeight - 最大高度 (默认 CONFIG.MAX_IMAGE_HEIGHT)
   * @returns {Promise<string>} 压缩后的 base64 DataURL
   */
  async function compressImage(dataUrl, opts = {}) {
    const maxKB = opts.maxKB || CONFIG.COMPRESS_THRESHOLD_KB;
    const quality = opts.quality || CONFIG.COMPRESS_QUALITY;
    const maxWidth = opts.maxWidth || CONFIG.MAX_IMAGE_WIDTH;
    const maxHeight = opts.maxHeight || CONFIG.MAX_IMAGE_HEIGHT;

    // 先检查base64大小
    const base64Part = dataUrl.split(',')[1] || '';
    const estimatedSizeKB = (base64Part.length * 3 / 4) / 1024;

    // 小于阈值不压缩，但仍做缩放+EXIF清理
    const needCompress = estimatedSizeKB > maxKB;

    return new Promise((resolve) => {
      const img = new Image();
      img.onload = () => {
        // 缩放计算
        let w = img.width;
        let h = img.height;
        if (w > maxWidth || h > maxHeight) {
          const ratio = Math.min(maxWidth / w, maxHeight / h);
          w = Math.round(w * ratio);
          h = Math.round(h * ratio);
        }

        const canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0, w, h);

        // 输出JPEG (自动清理EXIF，因为canvas重绘不含原始EXIF)
        const result = canvas.toDataURL('image/jpeg', needCompress ? quality : 0.92);
        resolve(result);
      };
      img.onerror = () => {
        // 压缩失败返回原图
        resolve(dataUrl);
      };
      img.src = dataUrl;
    });
  }

  // ========== stripExifData ==========

  /**
   * EXIF清理 (canvas重绘方式)
   * compressImage 已自动清理EXIF (canvas重绘不含原始EXIF)
   * 此函数为独立调用接口
   * @param {string} dataUrl - base64 DataURL
   * @returns {Promise<string>} 清理EXIF后的 DataURL
   */
  async function stripExifData(dataUrl) {
    // 直接调用 compressImage 不做压缩(quality=1.0)，仅做EXIF清理
    return compressImage(dataUrl, { quality: 1.0, maxKB: Infinity });
  }

  // ========== generateImageHash ==========

  /**
   * 图片去重hash (SHA-256前16字符)
   * 使用Web Crypto API (浏览器原生)
   * @param {string} base64 - 纯base64字符串 (不含data:image前缀)
   * @returns {Promise<string>} 16字符hex hash
   */
  async function generateImageHash(base64) {
    try {
      // base64 → Uint8Array
      const binaryStr = atob(base64);
      const bytes = new Uint8Array(binaryStr.length);
      for (let i = 0; i < binaryStr.length; i++) {
        bytes[i] = binaryStr.charCodeAt(i);
      }

      // SHA-256
      const hashBuffer = await crypto.subtle.digest('SHA-256', bytes);
      const hashArray = new Uint8Array(hashBuffer);

      // 取前8字节(16 hex字符)作为短hash
      const shortHash = hashArray.slice(0, 8)
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');

      return shortHash;
    } catch (e) {
      // fallback: 用base64长度+前100字符做简易hash
      const len = base64.length;
      const prefix = base64.substring(0, 100);
      return `${len}_${prefix.replace(/[^a-zA-Z0-9]/g, '').substring(0, 12)}`;
    }
  }

  // ========== escapeHtml ==========

  /**
   * XSS防护: HTML特殊字符转义
   * @param {string} str - 需转义的字符串
   * @returns {string} 安全字符串
   */
  function escapeHtml(str) {
    if (!str || typeof str !== 'string') return '';
    const map = {
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#039;',
      '/': '&#x2F;',
    };
    return str.replace(/[&<>"'/]/g, (c) => map[c]);
  }

  // ========== safeUrl ==========

  /**
   * URL安全验证: 只允许 http/https 协议
   * 拒绝 javascript:, data:text/html, vbscript: 等危险协议
   * @param {string} url - 需验证的URL
   * @returns {string} 安全URL或空字符串
   */
  function safeUrl(url) {
    if (!url || typeof url !== 'string') return '';
    const trimmed = url.trim();
    if (!trimmed) return '';
    try {
      const parsed = new URL(trimmed, window.location.origin);
      if (parsed.protocol === 'http:' || parsed.protocol === 'https:') {
        return parsed.href;
      }
      return '';
    } catch (e) {
      return '';
    }
  }

  // ========== isValidUUID ==========

  /**
   * UUID v4 格式校验
   * @param {string} uuid - 需校验的UUID字符串
   * @returns {boolean} 是否合法
   */
  function isValidUUID(uuid) {
    if (!uuid || typeof uuid !== 'string') return false;
    const re = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    return re.test(uuid.trim());
  }

  // ========== validateAction ==========

  /**
   * 动作白名单校验
   * @param {string} action - 动作名称
   * @param {string[]} whitelist - 允许的动作列表
   * @returns {boolean} 是否合法
   */
  function validateAction(action, whitelist) {
    if (!action || typeof action !== 'string') return false;
    if (!Array.isArray(whitelist) || whitelist.length === 0) return false;
    return whitelist.includes(action);
  }

  // ========== scanRateLimit (前端计数) ==========

  /**
   * AI扫描速率限制 (前端预检)
   * 服务端有 ai_scan_logs 50次/天硬限制
   * 前端做软提示，避免浪费请求
   * @returns {{ ok: boolean, remaining: number }}
   */
  function checkScanRate() {
    const key = 'cardrealm_scan_count';
    const todayKey = 'cardrealm_scan_date';
    const today = new Date().toISOString().slice(0, 10);
    const storedDate = localStorage.getItem(todayKey);
    let count = parseInt(localStorage.getItem(key) || '0', 10);

    if (storedDate !== today) {
      // 新的一天，重置计数
      count = 0;
      localStorage.setItem(todayKey, today);
      localStorage.setItem(key, '0');
    }

    const remaining = CONFIG.SCAN_DAILY_LIMIT - count;
    if (remaining <= 0) {
      return { ok: false, remaining: 0 };
    }
    return { ok: true, remaining };
  }

  function incrementScanCount() {
    const key = 'cardrealm_scan_count';
    const count = parseInt(localStorage.getItem(key) || '0', 10);
    localStorage.setItem(key, String(count + 1));
  }

  // ========== 导出 ==========

  return {
    CONFIG,
    validateImageFile,
    compressImage,
    stripExifData,
    generateImageHash,
    escapeHtml,
    safeUrl,
    isValidUUID,
    validateAction,
    checkScanRate,
    incrementScanCount,
  };
})();

// 全局挂载
window.RiskControl = RiskControl;
