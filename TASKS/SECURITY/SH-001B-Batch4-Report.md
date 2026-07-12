# SH-001B Batch 4 — XSS 安全加固报告

## 概述

**批次**: SH-001B Batch 4  
**日期**: 2026-07-12  
**范围**: 7个核心业务页面 XSS 安全加固  
**测试结果**: 98/98 全部通过 ✅  
**安全模块**: risk-control.js (统一安全中间件)

---

## 修改文件清单

| # | 文件 | 行数 | 状态 | 主要修复内容 |
|---|------|------|------|-------------|
| 1 | `my-reservations.html` | ~400 | ✅ 完成 | risk-control.js引入 + fail-closed + 事件委托(data-reservation-id) + 图片safeUrl + 数值校验 |
| 2 | `platform-store.html` | ~500 | ✅ 完成 | risk-control.js引入 + fail-closed + 事件委托(data-product-id) + 图片safeUrl + 数值校验 + 提交前校验 |
| 3 | `dashboard.html` | ~600 | ✅ 完成 | risk-control.js引入 + fail-closed + escapeHtml所有动态文本 + SVG createElementNS + DOM API柱状图 + 数值校验 |
| 4 | `my-assets.html` | ~700 | ✅ 完成 | risk-control.js引入 + fail-closed + 事件委托(data-collection-id) + SVG createElementNS + 图片safeUrl + 数值校验 |
| 5 | `points.html` | ~850 | ✅ 完成 | risk-control.js引入 + fail-closed + DOM API渲染(等级/签到/流水) + escapeHtml + 数值校验 + **不修改anon key** |
| 6 | `order.html` | ~640 | ✅ 完成 | risk-control.js引入 + fail-closed + escapeHtml(卡牌名/订单号/地址/物流) + 图片data-img-url+safeUrl + 数值校验 + URL参数isValidUUID + 保留静态onclick |
| 7 | `order-detail.html` | ~370 | ✅ 完成 | risk-control.js引入 + fail-closed + escapeHtml(订单号/商品名/物流/时间线) + 背景图data-bg-url+safeUrl + 物流链接safeUrl+域名白名单+rel=noopener + URL参数isValidUUID + showError DOM API |

---

## 安全防护体系

### 1. Fail-closed 安全检测

所有7个页面在 `<script>` 标签起始处添加了 fail-closed 检测：

```javascript
if (!window.RiskControl) {
    var fb = document.createElement('div');
    fb.style.cssText = '...';
    fb.textContent = '安全模块加载失败，请刷新页面重试';
    document.body.replaceChildren(fb);  // DOM API, 非 innerHTML
    throw new Error('RiskControl module not loaded');
}
```

- 使用 `document.body.replaceChildren()` (DOM API)，**不使用** `innerHTML` 覆盖 body
- 检测 `window.RiskControl` 不存在时，替换页面内容并中断执行

### 2. escapeHtml — 文本输出防护

所有来自数据库的动态文本均通过 `escapeHtml()` 转义：

| 数据来源 | 应用页面 | 防护方式 |
|---------|---------|---------|
| 卡牌名称 (card_name) | order, order-detail | `escapeHtml(c.card_name)` |
| 订单编号 (order_no) | order, order-detail | `escapeHtml(o.order_no)` |
| 收货地址 (buyer_address) | order | `escapeHtml(o.buyer_address?.name)` |
| 物流单号 (tracking_no) | order, order-detail | `escapeHtml(o.tracking_no)` |
| 物流公司 (shipping_carrier) | order-detail | `escapeHtml(order.shipping_carrier)` |
| 等级标题 (cfg.title) | points | `textContent` (DOM API) |
| 流水描述 (tx.description) | points | `textContent` (DOM API) |
| 物流时间线 (item.status) | order-detail | `escapeHtml(item.status)` |
| 卡牌标签 (tags) | order | `escapeHtml(String(t))` |
| 系列/稀有度/品相 | order | `escapeHtml(c.series)` 等 |

### 3. safeUrl + DOM API — 图片URL防护

**禁止**将图片URL直接拼入 `innerHTML` 的 `src` 或 `background-image` 属性。

**模式**：
1. 在 innerHTML 模板中使用 `data-img-url="${escapeHtml(url)}"` 或 `data-bg-url="${escapeHtml(url)}"` 存储URL
2. 设置 innerHTML 后，通过 DOM API 查询 `[data-img-url]` / `[data-bg-url]` 元素
3. 使用 `safeUrl()` 验证每个URL
4. 合法URL通过 `img.src = safe` 或 `el.style.backgroundImage = "url('" + safe + "')"` 设置
5. 非法URL（如 `javascript:`）清空src/backgroundImage并隐藏元素

**实现函数**：
- `order.html`: `processSafeImages(container)` — 处理 `<img data-img-url>`
- `order-detail.html`: `processSafeBgImages(container)` — 处理 `<div data-bg-url>`

### 4. isValidUUID — URL参数与事件委托防护

**URL参数校验**：
- `order.html`: `consignmentId` 和 `orderId` 通过 `isValidUUID()` 校验，非法值置为 `null`
- `order-detail.html`: `orderId` 通过 `isValidUUID()` 校验，非法值显示错误信息
- `order.html` `submitOrder()`: 返回的 `data[0].id` 通过 `isValidUUID()` 校验后才用于重定向

**事件委托 — 真实ID（非数组下标）**：

| 页面 | data属性 | 校验 | 查找方式 |
|------|---------|------|---------|
| my-reservations | `data-reservation-id` | `isValidUUID(resId)` | `allReservations.find(r => r.id === resId)` |
| platform-store | `data-product-id` | `isValidUUID(id)` | `products.find(x => x.id === id)` |
| my-assets | `data-collection-id` | `isValidUUID(collectionId)` | `currentCollections.find(c => c.id === collectionId)` |

**禁止使用数组下标**：`data-res-idx`、`data-product-idx`、`data-collection-idx` 均已消除。

### 5. 数值校验 — 业务范围限制

**价格校验** (`safePriceDisplay` / `safePriceRaw`):
```javascript
function safePriceDisplay(v) {
    var n = Number(v);
    return Number.isFinite(n) && n >= 0 ? n.toFixed(2) : '--';
}
```
- `Number.isFinite(n)` — 拒绝 NaN、Infinity、-Infinity
- `n >= 0` — 拒绝负数
- 无效值显示 `'--'`，**不静默转换为0**

**整数校验** (`safeIntDisplay` / `safeIntRaw`):
```javascript
function safeIntDisplay(v) {
    var n = Number(v);
    return Number.isInteger(n) && n >= 0 ? n.toLocaleString() : '--';
}
```
- `Number.isInteger(n)` — 拒绝非整数 (1.5, abc)
- `n >= 0` — 拒绝负数 (-1)
- 无效值显示 `'--'`

**提交前校验**:
- `order.html` `renderCheckout()`: `priceVal <= 0` 时阻止下单
- `order.html` `submitOrder()`: 价格和库存校验通过后才提交订单
- `platform-store.html` `reserveCard()`: 库存和价格校验后才允许预约

### 6. SVG / Tooltip 安全

**dashboard.html**:
- 柱状图: `document.createElement('div')` + `setAttribute('title', ...)` 而非模板字符串
- notice更新: `removeChild` + `createElement` + `createTextNode` 而非 `innerHTML`

**my-assets.html**:
- SVG圆点: `document.createElementNS(svgNS, 'circle')` + `setAttribute('data-value', ...)`
- 标签: `textContent` 设置日期
- tooltip: `textContent` 不返回未经处理的HTML

### 7. 静态 onclick 安全性

**order.html** 中的静态 onclick 处理器经确认安全保留：

| onclick | 参数 | 动态数据 | 安全性 |
|---------|------|---------|--------|
| `selectPay(this, 'alipay')` | 静态字符串 | 无 | ✅ 安全 |
| `selectPay(this, 'wechat')` | 静态字符串 | 无 | ✅ 安全 |
| `submitOrder()` | 无参数 | 无 | ✅ 安全 |
| `simulatePay()` | 无参数 | 无 | ✅ 安全 |
| `cancelOrder()` | 无参数 | 无 | ✅ 安全 |
| `confirmReceive()` | 无参数 | 无 | ✅ 安全 |
| `showShipForm()` | 无参数 | 无 | ✅ 安全 |
| `submitShip()` | 无参数 | 无 | ✅ 安全 |

**提交时仍进行检查**: `submitOrder()` 验证 `currentConsignment.id` (isValidUUID) + 价格 (safePriceRaw) + 返回ID (isValidUUID)。

### 8. 物流跟踪链接安全 (order-detail.html)

**showTrackingFallback()** 的安全加固：

1. **encodeURIComponent**: `order.tracking_no` 使用 `encodeURIComponent()` 编码后拼入URL
2. **safeUrl**: 构造的完整URL通过 `safeUrl()` 验证协议 (http/https only)
3. **域名白名单**: `LOGISTICS_DOMAINS` 数组限制只允许已知物流服务域名：
   - `www.sf-express.com` (顺丰)
   - `www.zto.com` (中通)
   - `www.yto.net.cn` (圆通)
   - `www.yundaexc.com` (韵达)
   - `www.sto.cn` (申通)
   - `www.800best.com` (百世)
   - `waybill.jd.com` (京东)
   - `www.kuaidi100.com` (快递100)
4. **rel="noopener noreferrer"**: `target="_blank"` 链接添加 `rel` 属性防止 tab-nabbing
5. **DOM API**: 链接通过 `document.createElement('a')` + `setAttribute` 创建，不通过 innerHTML

---

## 测试结果

### 测试覆盖

| 类别 | 测试数 | 通过 | 失败 |
|------|--------|------|------|
| A. risk-control.js 引入 + fail-closed | 21 | 21 | 0 |
| B. escapeHtml 使用 | 14 | 14 | 0 |
| C. safeUrl + DOM API 图片 | 10 | 10 | 0 |
| D. isValidUUID + 事件委托 | 8 | 8 | 0 |
| E. 数值校验 | 10 | 10 | 0 |
| F. XSS payload 阻断 | 15 | 15 | 0 |
| G. 静态 onclick 安全 | 4 | 4 | 0 |
| H. 物流链接安全 | 4 | 4 | 0 |
| I. 事件委托正确性 | 6 | 6 | 0 |
| J. Fail-closed DOM API | 4 | 4 | 0 |
| K. 配置未修改 | 2 | 2 | 0 |
| **总计** | **98** | **98** | **0** |

### XSS Payload 测试详情

| # | Payload | 攻击向量 | 防护方式 | 结果 |
|---|---------|---------|---------|------|
| 1 | `<script>alert('XSS')</script>` | 等级标题/流水描述 | textContent (DOM API) | ✅ 阻断 |
| 2 | `<img src=x onerror=alert('XSS')>` | 商品图片URL | data-img-url + safeUrl + DOM API | ✅ 阻断 |
| 3 | `javascript:alert('XSS')` | 图片URL/物流链接 | safeUrl() 协议白名单 | ✅ 阻断 |
| 4 | `"><script>alert('XSS')</script>` | 订单号/卡牌名 | escapeHtml() 6字符转义 | ✅ 阻断 |
| 5 | `<svg onload=alert('XSS')>` | 收货地址 | escapeHtml() | ✅ 阻断 |
| 6 | `${alert('XSS')}` | 模板字面量 | escapeHtml() 包裹输出 | ✅ 阻断 |
| 7 | `';alert('XSS');//` | 物流单号 | escapeHtml() | ✅ 阻断 |
| 8 | `-1` (价格) | 数值字段 | Number.isFinite && n >= 0 | ✅ 阻断 |
| 9 | `1.5` (积分) | 整数字段 | Number.isInteger | ✅ 阻断 |
| 10 | `Infinity` | 数值字段 | Number.isFinite | ✅ 阻断 |
| 11 | `NaN` | 数值字段 | Number.isFinite | ✅ 阻断 |
| 12 | `abc` | 数值字段 | Number() → NaN → isFinite | ✅ 阻断 |
| 13 | 非法UUID | URL参数 | isValidUUID() | ✅ 阻断 |
| 14 | 数组下标伪造 | 事件委托 | 真实ID + isValidUUID + 内存查找 | ✅ 阻断 |
| 15 | `data:text/html,<script>` | 物流链接 | safeUrl() + 域名白名单 | ✅ 阻断 |

### 业务回归测试

| 场景 | 验证内容 | 结果 |
|------|---------|------|
| 预约取消 | data-reservation-id + isValidUUID + find by id | ✅ 正确操作目标对象 |
| 商品预约 | data-product-id + isValidUUID + find by id | ✅ 正确操作目标对象 |
| 收藏关注 | data-collection-id + isValidUUID + find by id | ✅ 正确操作目标对象 |
| 订单创建 | 价格校验 + UUID校验 + 重定向安全 | ✅ 提交前校验通过 |
| 物流查询 | safeUrl + 域名白名单 + rel=noopener | ✅ 安全跳转 |
| 积分签到 | 数值校验 + RPC返回值校验 | ✅ 正确显示积分 |
| 排序/筛选后操作 | 真实ID查找(非数组下标) | ✅ 操作正确对象 |

---

## 用户9项修正执行确认

| # | 修正要求 | 执行状态 |
|---|---------|---------|
| 1 | 删除 points.html "更新 anon key" 改动 | ✅ 未修改 anon key (测试K验证) |
| 2 | 禁止数组下标作为业务标识 | ✅ 全部使用 data-*-id + isValidUUID + find by id |
| 3 | 图片 safeUrl + DOM API | ✅ data-img-url/data-bg-url + safeUrl + DOM API |
| 4 | 数值业务范围校验 | ✅ 价格 isFinite&&>=0, 积分 isInteger&&>=0, 无效显示'--' |
| 5 | SVG/tooltip 用 textContent/setAttribute | ✅ createElementNS + setAttribute + textContent |
| 6 | Fail-closed 用 DOM API | ✅ replaceChildren/createElement/textContent |
| 7 | URL白名单(域名) | ✅ safeUrl http/https + 物流域名白名单 |
| 8 | order.html 静态 onclick 保留 | ✅ 确认无动态数据, 提交时仍校验 |
| 9 | 物流链接 safeUrl + rel=noopener | ✅ safeUrl + 域名白名单 + rel=noopener noreferrer |

---

## 未修改项确认

以下内容在本批次中**未做任何修改**：

- ❌ 数据库结构 / RLS 策略
- ❌ 支付状态机
- ❌ AI 识卡功能
- ❌ 定价引擎
- ❌ Supabase 配置和密钥
- ❌ risk-control.js 模块本身 (Batch 1/2/3 已建立)

---

## 后续建议

1. **0037 SQL 迁移**: Storage MIME/size 限制 SQL 仍待在线上执行 (SEC-004 遗留)
2. **SH-001B Batch 3-5**: 其余约20个文件的 XSS 修复待执行
3. **同步部署**: 修改后的7个文件需同步到线上 Supabase Storage
4. **Git 提交**: 建议创建 commit 并打 tag `v0.9.4-xss-batch4`

---

## 文件索引

| 文件 | 路径 |
|------|------|
| 安全模块 | `js/risk-control.js` |
| 预约列表 | `my-reservations.html` |
| 平台商城 | `platform-store.html` |
| 数据看板 | `dashboard.html` |
| 我的资产 | `my-assets.html` |
| 积分中心 | `points.html` |
| 订单确认 | `order.html` |
| 订单详情 | `order-detail.html` |
| 测试文件 | `tests/xss-batch4-test.js` |
| 本报告 | `TASKS/SECURITY/SH-001B-Batch4-Report.md` |

---

*报告生成时间: 2026-07-12 23:39*  
*测试执行: Node.js v22.22.2*  
*安全模块版本: risk-control.js (Batch 1/2/3 建立)*
