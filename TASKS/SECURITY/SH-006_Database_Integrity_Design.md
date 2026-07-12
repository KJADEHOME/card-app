# SH-006: Database Integrity 设计方案

> **项目**: 卡域 CardRealm
> **阶段**: 设计方案 (Design Only — 不修改数据库)
> **日期**: 2026-07-13
> **状态**: 待审核

---

## 一、扫描范围

对 0001-0037 全部迁移文件中的 **68 个表**进行完整性扫描，覆盖：
- 外键约束 (Foreign Key)
- ON DELETE / ON UPDATE 策略
- 字符串关联 vs UUID 外键
- 孤儿数据风险
- 级联删除安全性

---

## 二、问题总览

| 问题类型 | 数量 | 严重等级 |
|----------|------|----------|
| **字符串关联 (card_name TEXT)** | 20+ 表 | **高** — 系统级架构缺陷 |
| **缺失 ON DELETE 策略** | 3 处 | 中 — 可能阻止合法删除 |
| **ON DELETE 策略不一致** | 5 处 | 中 — 金融数据可能丢失/孤立 |
| **缺失 FK 约束** | 4 处 | 中 — 无法防止无效引用 |
| **profiles 表无 FK 到 auth.users** | 1 处 | 低 — 需评估添加风险 |

---

## 三、问题详细清单

### 3.1 字符串关联：card_name TEXT (最高优先级)

**核心问题**：项目没有统一的 `cards` 主表，20+ 个表使用 `card_name TEXT` 作为卡牌标识，形成字符串关联网络。

#### 受影响表

| 表 | 迁移 | card_name 用途 | 当前关联方式 |
|----|------|----------------|-------------|
| price_history | 0003/0011 | 价格记录的卡牌 | 字符串 |
| daily_market_stats | 0011 | 市场统计的卡牌 | 字符串 |
| card_prices | 0011 | 价格快照的卡牌 | 字符串 |
| user_collections | 0004 | 用户收藏的卡牌 | 字符串 |
| collection_price_snapshots | 0004 | 收藏价格快照 | 字符串 |
| community_posts | 0005 | 帖子关联卡牌 | 字符串 |
| trending_scans | 0005 | 热门扫描卡牌 | 字符串 |
| consignments | 0006 | 寄售卡牌 | 字符串 |
| scan_history | 0008 | 扫描历史 | 字符串 |
| trade_records | 0008 | 交易记录 | 字符串 |
| ai_scan_logs | 0010 | AI识别结果 | 字符串 |
| ai_scan_cache | 0013 | AI缓存 | 字符串 |
| risk_events | 0013 | 风控事件 | 字符串 |
| trade_frequency_logs | 0013 | 交易频率 | 字符串 |
| card_market | 0021 | 市场定价卡牌 | 字符串 (有独立 UUID PK) |
| portfolio_items | 0021 | 持仓卡牌 | 字符串 |
| price_watchlist | 0015 | 关注列表 | 字符串 |
| price_change_events | 0024 | 价格变动 | 字符串 |
| price_activity_stats | 0025 | 价格活跃度 | 字符串 |
| live_sync_items | 0032 | 直播同步卡牌 | 字符串 |

**风险**：
1. 卡牌名称变更 → 所有关联记录变为孤儿
2. 同名卡牌不同版本 → 无法区分（如 "皮卡丘" 可能有 50+ 种版本）
3. 无法做 JOIN 查询的 FK 级联
4. 字符串索引比 UUID 索引慢且占用更多空间

#### 设计方案

**不推荐立即替换为 UUID FK**，原因：
- 影响 20+ 表，涉及大量数据迁移
- card_market 表本身用 card_name 作为业务键，没有独立的 cards 主表
- 修改风险极高，可能破坏定价引擎和触发器链

**推荐分阶段方案**：

**Phase 1 (当前)**：创建 `cards` 主表，不动现有表
```sql
CREATE TABLE public.cards (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    card_name TEXT NOT NULL,
    card_name_en TEXT,
    set_name TEXT,
    set_code TEXT,
    card_number TEXT,
    rarity TEXT,
    image_url TEXT,
    category TEXT,  -- pokemon/yugioh/mtg
    -- 元数据
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(card_name, set_name, card_number)
);
```

**Phase 2 (后续)**：在 card_market 表增加 `card_id UUID REFERENCES cards(id)`，逐步回填

**Phase 3 (长期)**：其他表逐步增加 card_id FK，最终废弃 card_name 字符串关联

### 3.2 缺失 ON DELETE 策略

| 表 | 列 | FK 目标 | 当前策略 | 建议策略 | 原因 |
|----|-----|---------|----------|----------|------|
| live_sessions | host_id | auth.users(id) | **NO ACTION** (默认) | ON DELETE SET NULL | 用户删除时保留直播记录历史 |
| sealed_product_orders | sealed_product_id | sealed_products(id) | **NO ACTION** (默认) | ON DELETE RESTRICT | 有订单时禁止删除商品 |
| merchandise_orders | merchandise_id | merchandise(id) | **NO ACTION** (默认) | ON DELETE RESTRICT | 有订单时禁止删除商品 |

**风险**：
- `live_sessions.host_id` 无 ON DELETE → 删除用户时数据库报错，事务回滚
- 两个订单表 → 删除商品时如果有关联订单，数据库报错

### 3.3 ON DELETE 策略不一致

#### 3.3.1 auth.users 删除策略

| 表 | 列 | 当前策略 | 问题 |
|----|-----|----------|------|
| user_collections | user_id | CASCADE | ✅ 合理 — 用户删除则收藏清空 |
| user_points | user_id | CASCADE | ✅ 合理 |
| consignments | seller_id | CASCADE | ✅ 合理 |
| orders | buyer_id | SET NULL | ⚠️ 买家删除后订单失去买方信息 |
| orders | seller_id | SET NULL | ⚠️ 卖家删除后订单失去卖方信息 |
| escrow_transactions | from_user_id | SET NULL | ⚠️ 资金流水失去一方信息 |
| escrow_transactions | to_user_id | SET NULL | ⚠️ 同上 |
| trade_records | seller_id | SET NULL | ⚠️ 交易记录失去卖方 |
| trade_records | buyer_id | SET NULL | ⚠️ 交易记录失去买方 |
| notifications | user_id | CASCADE | ✅ 合理 |
| community_posts | user_id | CASCADE | ⚠️ 帖子被删，评论怎么处理? (评论 CASCADE OK) |
| refunds | user_id | SET NULL | ✅ 合理 — 保留退款记录 |
| disputes | initiator_id | SET NULL | ✅ 合理 — 保留争议记录 |
| disputes | order_id | CASCADE | ⚠️ 订单删除则争议消失 |
| escrow_records | buyer_id | CASCADE | **危险** — 买家删除则托管记录消失 |
| escrow_records | seller_id | CASCADE | **危险** — 卖家删除则托管记录消失 |

**关键风险**：`escrow_records` 的 buyer_id 和 seller_id 都设为 CASCADE (0035迁移)。如果买家或卖家删除账号，托管记录会被级联删除，导致资金审计链断裂。

#### 3.3.2 orders 删除策略

| 表 | 列 | 当前策略 | 问题 |
|----|-----|----------|------|
| escrow_transactions | order_id | CASCADE | 订单删除则资金流水消失 |
| platform_fees | order_id | SET NULL | ✅ 保留手续费记录 |
| wallet_transactions | order_id | SET NULL | ✅ 保留钱包流水 |
| trade_records | order_id | SET NULL | ✅ 保留交易记录 |
| refunds | order_id | CASCADE | 订单删除则退款记录消失 |
| disputes | order_id | CASCADE | 订单删除则争议记录消失 |
| notifications | (order相关) | — | 通过 user_id CASCADE 间接处理 |

**关键风险**：`refunds` 和 `disputes` 使用 CASCADE，订单删除会删除退款和争议记录。对于金融系统，这些记录应该永久保留。

### 3.4 缺失 FK 约束

| 表 | 列 | 类型 | 应关联到 | 当前状态 | 风险 |
|----|-----|------|----------|----------|------|
| profiles | id | UUID | auth.users(id) | **无 FK** | auth.users 删除后 profiles 孤儿 |
| profiles | disabled_by | UUID | auth.users(id) | **有 FK，无 ON DELETE** | 0031迁移添加，NO ACTION |
| profiles | merchant_verified_by | UUID | auth.users(id) | **有 FK，无 ON DELETE** | 0032迁移添加，NO ACTION |
| payment_orders | user_id | UUID | auth.users(id) | **有 FK (CASCADE)** | ✅ |
| consignments | collection_id | UUID | user_collections(id) | **有 FK (SET NULL)** | ✅ 0012迁移添加 |

**profiles.id 无 FK 的原因**：profiles 表通常通过 trigger 从 auth.users 自动创建，添加 FK 可能导致 chicken-and-egg 问题。但可以添加 **DEFERRABLE** FK。

### 3.5 其他完整性问题

#### 3.5.1 重复表定义

| 表 | 定义位置 | 问题 |
|----|----------|------|
| price_history | 0003 和 0011 | 0011 使用 `CREATE TABLE IF NOT EXISTS`，可能已有旧结构 |
| daily_market_stats | 0003 和 0011 | 同上 |
| user_collections | 0004 和 0011 | 0011 重新定义，可能与 0004 不一致 |
| collection_price_snapshots | 0004 和 0011 | 同上 |
| notifications | 0008 和 0018 | 0018 使用 `CREATE TABLE IF NOT EXISTS`，可能已有旧结构 |
| platform_config | 0006 和 0035 | 0035 重新定义，可能与 0006 不一致 |

#### 3.5.2 admins 表 FK 风险 (SH-003 关联)

如果 SH-003 废弃 admins 表，以下表的 `admin_id` FK 会受影响：
- platform_cards.admin_id → admins(id) ON DELETE SET NULL
- platform_issue_logs.admin_id → admins(id) ON DELETE SET NULL
- sealed_products.admin_id → admins(id) ON DELETE SET NULL
- merchandise.admin_id → admins(id) ON DELETE SET NULL

**建议**：这些 FK 改为 `ON DELETE SET NULL`（已是），admins 表保留数据不删除即可。

---

## 四、设计方案

### 4.1 ON DELETE 策略统一规范

#### 原则

| 数据类型 | 删除策略 | 原因 |
|----------|----------|------|
| 用户内容 (收藏/帖子/评论) | CASCADE | 用户删除则内容清空 |
| 金融记录 (订单/退款/争议/托管) | **SET NULL** | 金融记录必须永久保留 |
| 交易关联 (consignments) | CASCADE 或 SET NULL | 视场景而定 |
| 审计日志 | SET NULL | 保留操作记录 |
| 直播/活动 | SET NULL | 保留历史 |

#### 需修改的 ON DELETE 策略

| 表 | 列 | 当前 | 目标 | 迁移方式 |
|----|-----|------|------|----------|
| escrow_records | buyer_id | CASCADE | **SET NULL** | DROP + ADD CONSTRAINT |
| escrow_records | seller_id | CASCADE | **SET NULL** | DROP + ADD CONSTRAINT |
| refunds | order_id | CASCADE | **SET NULL** | DROP + ADD CONSTRAINT |
| disputes | order_id | CASCADE | **SET NULL** | DROP + ADD CONSTRAINT |
| live_sessions | host_id | NO ACTION | **SET NULL** | DROP + ADD CONSTRAINT |
| sealed_product_orders | sealed_product_id | NO ACTION | **RESTRICT** | DROP + ADD CONSTRAINT |
| merchandise_orders | merchandise_id | NO ACTION | **RESTRICT** | DROP + ADD CONSTRAINT |

### 4.2 新增 FK 约束

| 表 | 列 | 目标 | ON DELETE | 备注 |
|----|-----|------|-----------|------|
| profiles | id | auth.users(id) | CASCADE | DEFERRABLE INITIALLY DEFERRED |

**注意**：profiles.id 添加 FK 需要使用 `DEFERRABLE INITIALLY DEFERRED`，因为 profiles 是由 trigger 在 auth.users INSERT 后自动创建的，非 DEFERRABLE FK 会阻止 trigger 执行。

### 4.3 cards 主表 (Phase 1)

```sql
CREATE TABLE IF NOT EXISTS public.cards (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    card_name TEXT NOT NULL,
    card_name_en TEXT,
    set_name TEXT,
    set_code TEXT,
    card_number TEXT,
    rarity TEXT,
    image_url TEXT,
    category TEXT DEFAULT 'pokemon'
        CHECK (category IN ('pokemon', 'yugioh', 'mtg', 'onepiece', 'other')),
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(card_name, set_name, card_number)
);

CREATE INDEX idx_cards_name ON public.cards(card_name);
CREATE INDEX idx_cards_category ON public.cards(category);
CREATE INDEX idx_cards_set ON public.cards(set_name);

-- RLS: 所有人可读，仅 service_role 可写
ALTER TABLE public.cards ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cards_read_all" ON public.cards FOR SELECT USING (true);
```

### 4.4 重复表清理评估

| 重复表 | 建议 | 风险 |
|--------|------|------|
| price_history (0003 vs 0011) | 检查线上结构是否与 0011 一致 | 低 — IF NOT EXISTS 保护 |
| daily_market_stats (0003 vs 0011) | 同上 | 低 |
| user_collections (0004 vs 0011) | 检查列是否完整 | 中 — 0011 可能缺少 0004 的列 |
| collection_price_snapshots (0004 vs 0011) | 同上 | 中 |
| notifications (0008 vs 0018) | 检查列结构 | 低 |
| platform_config (0006 vs 0035) | 检查列结构 | 低 |

**建议**：执行前先运行结构检查脚本验证线上表结构。

---

## 五、迁移脚本设计 (0039)

```sql
-- 0039: 数据库完整性加固
-- 注意: 本文件为设计方案，待审核后执行

-- ============================================
-- Part 1: 修复 ON DELETE 策略
-- ============================================

-- 1.1 escrow_records: CASCADE → SET NULL (金融记录保护)
ALTER TABLE public.escrow_records
  DROP CONSTRAINT IF EXISTS escrow_records_buyer_id_fkey,
  DROP CONSTRAINT IF EXISTS escrow_records_seller_id_fkey;

ALTER TABLE public.escrow_records
  ADD CONSTRAINT escrow_records_buyer_id_fkey
    FOREIGN KEY (buyer_id) REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD CONSTRAINT escrow_records_seller_id_fkey
    FOREIGN KEY (seller_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- 1.2 refunds: CASCADE → SET NULL
ALTER TABLE public.refunds
  DROP CONSTRAINT IF EXISTS refunds_order_id_fkey;

ALTER TABLE public.refunds
  ADD CONSTRAINT refunds_order_id_fkey
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL;

-- 1.3 disputes: CASCADE → SET NULL
ALTER TABLE public.disputes
  DROP CONSTRAINT IF EXISTS disputes_order_id_fkey;

ALTER TABLE public.disputes
  ADD CONSTRAINT disputes_order_id_fkey
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL;

-- 1.4 live_sessions: NO ACTION → SET NULL
ALTER TABLE public.live_sessions
  DROP CONSTRAINT IF EXISTS live_sessions_host_id_fkey;

ALTER TABLE public.live_sessions
  ADD CONSTRAINT live_sessions_host_id_fkey
    FOREIGN KEY (host_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- 1.5 sealed_product_orders: NO ACTION → RESTRICT
ALTER TABLE public.sealed_product_orders
  DROP CONSTRAINT IF EXISTS sealed_product_orders_sealed_product_id_fkey;

ALTER TABLE public.sealed_product_orders
  ADD CONSTRAINT sealed_product_orders_sealed_product_id_fkey
    FOREIGN KEY (sealed_product_id) REFERENCES public.sealed_products(id) ON DELETE RESTRICT;

-- 1.6 merchandise_orders: NO ACTION → RESTRICT
ALTER TABLE public.merchandise_orders
  DROP CONSTRAINT IF EXISTS merchandise_orders_merchandise_id_fkey;

ALTER TABLE public.merchandise_orders
  ADD CONSTRAINT merchandise_orders_merchandise_id_fkey
    FOREIGN KEY (merchandise_id) REFERENCES public.merchandise(id) ON DELETE RESTRICT;

-- ============================================
-- Part 2: 新增 FK 约束
-- ============================================

-- 2.1 profiles.id → auth.users(id) (DEFERRABLE)
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_id_fkey;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_id_fkey
    FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE
    DEFERRABLE INITIALLY DEFERRED;

-- 2.2 profiles.disabled_by ON DELETE 策略
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_disabled_by_fkey;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_disabled_by_fkey
    FOREIGN KEY (disabled_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- 2.3 profiles.merchant_verified_by ON DELETE 策略
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_merchant_verified_by_fkey;

ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_merchant_verified_by_fkey
    FOREIGN KEY (merchant_verified_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- ============================================
-- Part 3: 创建 cards 主表 (Phase 1)
-- ============================================
-- (见 4.3 节)

-- ============================================
-- Part 4: 添加 card_market.card_id (可选, Phase 2)
-- ============================================
-- ALTER TABLE public.card_market
--   ADD COLUMN IF NOT EXISTS card_id UUID REFERENCES public.cards(id) ON DELETE SET NULL;
-- CREATE INDEX IF NOT EXISTS idx_card_market_card_id ON public.card_market(card_id);
```

---

## 六、风险评估

| 风险 | 等级 | 缓解措施 |
|------|------|----------|
| 修改 ON DELETE 策略需要短暂锁表 | 低 | 在低峰期执行；ALTER CONSTRAINT 通常很快 |
| profiles.id 添加 FK 可能因孤儿数据失败 | 中 | 执行前先检查并清理孤儿 profiles 记录 |
| cards 主表创建后无人使用 | 低 | Phase 1 仅创建表，不影响现有逻辑 |
| 重复表结构不一致导致迁移失败 | 中 | 执行前运行结构检查脚本 |
| escrow_records FK 修改影响进行中的交易 | 中 | 确保无进行中的托管交易时执行 |

---

## 七、执行前检查脚本

```sql
-- 执行前检查：profiles 孤儿记录
SELECT COUNT(*) AS orphan_profiles
FROM public.profiles p
LEFT JOIN auth.users u ON p.id = u.id
WHERE u.id IS NULL;

-- 执行前检查：escrow_records 孤儿用户
SELECT COUNT(*) AS orphan_escrow_buyers
FROM public.escrow_records e
LEFT JOIN auth.users u ON e.buyer_id = u.id
WHERE e.buyer_id IS NOT NULL AND u.id IS NULL;

-- 执行前检查：重复表结构
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'user_collections' AND table_schema = 'public'
ORDER BY ordinal_position;
```

---

## 八、与 SH-003 的关联

| 关联点 | 说明 |
|--------|------|
| admins 表 FK | SH-003 废弃 admins 表后，platform_cards/sealed_products/merchandise 的 admin_id FK 仍指向 admins(id)。建议保留 admins 表数据，FK 不变 |
| admin_audit_logs | SH-003 新增的审计日志表，其 admin_id 应 REFERENCES auth.users(id) ON DELETE SET NULL |
| profiles.role RLS | SH-003 加固 profiles.role 的 RLS，与本文 profiles.id FK 互补 |

---

## 九、优先级排序

| 优先级 | 任务 | 影响 | 紧急度 |
|--------|------|------|--------|
| **P0** | 修复 escrow_records CASCADE → SET NULL | 防止资金记录丢失 | 高 |
| **P0** | 修复 refunds/disputes CASCADE → SET NULL | 防止退款/争议记录丢失 | 高 |
| **P1** | 修复 live_sessions ON DELETE 策略 | 防止用户删除失败 | 中 |
| **P1** | 添加 profiles.id FK | 防止孤儿 profiles | 中 |
| **P2** | 修复 sealed_product_orders/merchandise_orders ON DELETE | 防止商品删除失败 | 中 |
| **P2** | 创建 cards 主表 (Phase 1) | 为长期架构改进铺路 | 低 |
| **P3** | card_market 添加 card_id (Phase 2) | 字符串关联迁移 | 低 |
| **P3** | 全表 card_name → card_id 迁移 (Phase 3) | 彻底解决字符串关联 | 低 |

---

## 十、完整表关系图 (核心表)

```
auth.users (Supabase 内置)
  │
  ├── profiles (id FK, DEFERRABLE)
  │     ├── role: user | merchant | admin
  │     └── merchant_verified_by (FK, SET NULL)
  │
  ├── user_collections (CASCADE)
  │     ├── card_name (字符串关联 ⚠️)
  │     └── collection_id ← consignments (SET NULL)
  │                └── orders (SET NULL)
  │                       ├── escrow_transactions (order_id CASCADE ⚠️→SET NULL)
  │                       ├── platform_fees (SET NULL)
  │                       ├── wallet_transactions (SET NULL)
  │                       ├── trade_records (SET NULL)
  │                       ├── refunds (CASCADE ⚠️→SET NULL)
  │                       ├── disputes (CASCADE ⚠️→SET NULL)
  │                       ├── notifications (CASCADE)
  │                       └── escrow_records (buyer/seller CASCADE ⚠️→SET NULL)
  │
  ├── user_points (CASCADE)
  │     └── point_transactions (CASCADE)
  │
  ├── consignments (seller_id CASCADE)
  │     └── card_name (字符串关联 ⚠️)
  │
  ├── card_market (card_name 字符串键 ⚠️)
  │     ├── price_history (字符串关联 ⚠️)
  │     ├── price_change_events (字符串关联 ⚠️)
  │     ├── portfolio_items (字符串关联 ⚠️)
  │     └── price_activity_stats (字符串关联 ⚠️)
  │
  ├── live_sessions (host_id NO ACTION ⚠️→SET NULL)
  │     └── live_sync_items (CASCADE)
  │
  ├── platform_cards (admin_id → admins, SET NULL)
  │     └── pre_orders (RESTRICT)
  │
  ├── payment_orders (CASCADE)
  │     └── escrow_records (order_id CASCADE, buyer/seller CASCADE ⚠️)
  │
  └── admin_audit_logs (SH-003 新增, SET NULL)
```

---

*本文件为 SH-006 设计方案，等待王总审核后进入实施阶段。*
