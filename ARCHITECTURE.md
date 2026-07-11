# ARCHITECTURE.md — 卡域 CardRealm 系统架构

> **版本**: 1.0 | **更新**: 2026-07-08 | **适用**: 卡域APP全项目

---

## 1. 系统架构总览

```
┌─────────────────────────────────────────────┐
│                  PWA 前端                     │
│  (HTML/CSS/JS · Service Worker · manifest)   │
│                                              │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐       │
│  │识卡  │ │市场  │ │交易  │ │资产  │       │
│  │scan  │ │market│ │trade │ │assets│       │
│  └──────┘ └──────┘ └──────┘ └──────┘       │
│                                              │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐       │
│  │社区  │ │商城  │ │钱包  │ │管理  │       │
│  │comm  │ │shop  │ │wallet│ │admin │       │
│  └──────┘ └──────┘ └──────┘ └──────┘       │
└──────────────────────┬──────────────────────┘
                       │ Supabase Client (anon key)
                       ▼
┌─────────────────────────────────────────────┐
│            Supabase 后端                      │
│                                              │
│  ┌─────────┐  ┌─────────┐  ┌──────────┐    │
│  │  Auth   │  │Database │  │ Storage  │    │
│  │(GoTrue) │  │(PG15)   │  │(S3-like) │    │
│  └─────────┘  └─────────┘  └──────────┘    │
│                                              │
│  ┌──────────────────────────────────┐       │
│  │     Edge Functions               │       │
│  │  ai-scan / price-updater / api   │       │
│  └──────────────────────────────────┘       │
└─────────────────────────────────────────────┘
```

---

## 2. 前端模块划分

### 2.1 页面入口（单页HTML）

| 页面 | 文件 | 功能域 |
|---|---|---|
| 首页 | `index.html` / `home.html` | 导航入口 |
| 登录 | `login.html` | Supabase Auth |
| 识卡 | `scan-history.html` | AI识卡入口 |
| 收藏 | `collection.html` | 用户卡牌库 |
| 市场行情 | `market.html` / `market_feed.html` | 价格走势 |
| 交易市场 | `marketplace.html` | 买卖挂单 |
| 平台商城 | `platform-store.html` | 平台自营卡 |
| 卡牌详情 | `card-detail.html` | 单卡信息 |
| 上架出售 | `sell.html` / `publish.html` | 挂单创建 |
| 下单购买 | `order.html` / `order-confirm.html` | 购买流程 |
| 订单管理 | `my-orders.html` / `order-detail.html` | 订单追踪 |
| 资产总览 | `my-assets.html` / `dashboard.html` | 持仓+盈亏 |
| 预约购买 | `my-reservations.html` | 商城预约 |
| 我的上架 | `my-listings.html` | 挂单管理 |
| 钱包 | `wallet.html` / `recharge.html` | 余额+充值 |
| 积分 | `points.html` | 积分体系 |
| 社区 | `community.html` | 动态+互动 |
| 消息 | `message.html` / `notifications.html` | 通知中心 |
| 反馈 | `feedback.html` | 用户反馈 |
| 签到 | `checkins.sql` | 签到体系 |
| 个人 | `profile.html` | 用户资料 |
| 管理后台 | `admin.html` + `admin-{模块}.html` | 多模块后台 |
| 平台管理 | `admin-platform-login/publish.html` | 平台发行 |
| 测试 | `test-payment.html` / `test-ai-scan.js` | 调试工具 |

### 2.2 JS 模块结构

```
js/
├── supabase-client.js    ← Supabase 初始化 + anon key
├── auth.js               ← 登录/注册/会话管理
├── scan.js               ← AI识卡调用
├── market.js             ← 市场数据
├── trade.js              ← 交易操作
├── portfolio.js          ← 资产计算
├── wallet.js             ← 钱包操作
├── admin.js              ← 管理后台
├── ...                   ← 各页面专属JS
```

---

## 3. 后端架构 — Supabase

### 3.1 Auth 体系

- **用户认证**: Supabase GoTrue (Email/Phone + OAuth)
- **管理员认证**: 独立 `admins` 表 (session_token机制，与auth.users隔离)
- **商家认证**: profiles.role 字段 (admin/merchant/user)

### 3.2 Edge Functions

| Function | 路径 | 用途 |
|---|---|---|
| ai-scan | `supabase/functions/ai-scan/` | Gemini识卡 (v4.1, 降级策略) |
| price-updater | `supabase/functions/price-updater/` | 价格波动+快照 (v4) |
| api | `server/api.js` | 本地开发API代理 |

**部署方式**: `npx supabase functions deploy <name>` + PAT
**注意**: Edge Function需 `cp index.js → index.ts` (Management API不编译TS)

---

## 4. 数据流架构

### 4.1 核心数据流

```
用户拍照 → ai-scan Edge Function → Gemini API
    ↓
识别结果(success/partial/failed)
    ↓
complete_card_entry RPC → user_collections + card_market + card_prices
    ↓
价格体系触发器链 → final_price → portfolio_items → user_portfolio
```

### 4.2 价格触发器链（核心，禁止修改计算顺序）

```
card_prices INSERT/UPDATE
  → trg_card_prices_to_market
  → card_market.market_price 更新

card_market INSERT/UPDATE (BEFORE触发器)
  → trg_card_market_price
  → 计算 final_price (三级定价: live→market→ai→0)
  → 锁定逻辑 (price_locked → final_price = locked_price)
  → 计算 unlocked_price
  → CHECK约束验证

card_market final_price 变更
  → trg_market_to_portfolio
  → portfolio_items.current_price 更新

card_market unlocked_price 变更
  → trg_log_price_changes (0024)
  → price_change_events (≥5%变动记录)

portfolio_items 变更
  → trg_portfolio_auto_refresh
  → user_portfolio + user_daily_snapshot 更新
```

### 4.3 交易数据流

```
创建挂单: create_consignment_from_collection → 冻结库存
购买挂单: purchase_consignment → FOR UPDATE行锁 → 原子交易 → 自营0手续费
取消挂单: cancel_consignment → 释放库存
直播同步: sync_card_to_live → consignment + live_sync_items
预约购买: create_pre_order → 锁定mark_price → 24h过期
平台发行: admin_publish_card → card_market(source_type=platform) + platform_cards
```

---

## 5. 三级定价体系（0023 锁死，禁止修改）

```
final_price 优先级:
  live_price    (实时价, 最高优先)
  → market_price (市场价, 中间)
  → ai_estimate_price (AI估价, 兜底)
  → 0 (无数据)
```

**三层防护**:
1. BEFORE INSERT/UPDATE 触发器（全列）强制计算
2. CHECK `chk_price_truth_rule` 约束
3. CHECK `chk_price_source_values` 约束
4. `verify_price_truth_rule()` 验证函数

---

## 6. 价格锁定机制（0024）

- `card_market` 字段: `price_locked`, `locked_price`, `lock_expires_at`
- 锁定时: `final_price = locked_price` (固定不变)
- 过期自动解锁: 触发器处理
- 未锁定: `final_price = unlocked_price` (正常计算)
- RPC: `lock_card_price`, `unlock_card_price`, `check_and_auto_lock_prices`

---

## 7. PWA 架构

- `manifest.json`: 应用配置
- `service-worker.js` / `sw.js`: 离线缓存策略
- 离线优先：核心页面缓存，API请求网络优先
- 部署域名: `cardrealm.top` (Cloudflare Pages)

---

## 8. 外部依赖

| 服务 | 用途 | 依赖等级 |
|---|---|---|
| Supabase | 全后端 | 核心（不可替代） |
| Gemini API | AI识卡 | 核心（有降级策略） |
| Cloudflare | CDN + Pages | 核心 |
| pgcrypto | 密码哈希 | 核心（extensions schema） |

---

## 9. 部署架构

```
本地开发 → server/api.js (Node代理)
         → Supabase Local (可选)

生产部署 → Cloudflare Pages (前端静态)
         → Supabase Cloud (后端)
         → Edge Functions (AI/价格)

域名     → cardrealm.top
         → *.cardrealm.top (子域预留)
```

---

*本文件定义系统架构边界，架构变更需王总审批。*
