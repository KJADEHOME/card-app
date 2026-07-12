# SH-006B: Database Integrity — FINAL MIGRATION PLAN

> **项目**: 卡域 CardRealm
> **阶段**: 最终迁移计划 (Plan Only — 不修改数据库)
> **日期**: 2026-07-13
> **状态**: 待王总审核
> **前置文档**: SH-006 设计方案 (已审核，提出修订要求)

---

## 一、迁移拆分总览

原 SH-006 设计方案将所有数据库改动放入单个 0039 迁移。根据修订要求，拆分为 3 个独立迁移，每个可独立执行、独立回滚。

```
0039_financial_fk_safety.sql    ← P0: 金融记录 FK 安全
         │
         ▼
0040_profiles_auth_fk.sql       ← P1: profiles ↔ auth.users FK
         │
         ▼
0041_cards_master_phase1.sql    ← P2: cards 主表 (仅创建，不动现有表)
```

| 迁移 | 优先级 | 影响 | 可独立回滚 | 依赖 |
|------|--------|------|-----------|------|
| 0039 | **P0** | 4 个表 FK 约束修改 | ✅ 是 | 无 |
| 0040 | P1 | 1 个表新增 FK + 2 个 FK 策略修改 | ✅ 是 | 0039 (无直接依赖，但建议先执行 0039) |
| 0041 | P2 | 1 个新表 | ✅ 是 | 无 |

---

## 二、0039_financial_fk_safety.sql

### 2.1 目标

修复金融记录表的 ON DELETE 策略，确保用户或订单删除时，金融、退款、争议记录不丢失。

### 2.2 影响范围

| 表 | 列 | 当前策略 | 目标策略 | 原因 |
|----|-----|---------|---------|------|
| escrow_records | buyer_id | CASCADE | **SET NULL** | 买家删除账号时保留托管资金记录 |
| escrow_records | seller_id | CASCADE | **SET NULL** | 卖家删除账号时保留托管资金记录 |
| refunds | order_id | CASCADE | **SET NULL** | 订单删除时保留退款记录 |
| disputes | order_id | CASCADE | **SET NULL** | 订单删除时保留争议记录 |

**不受影响的表** (已合理):
- escrow_transactions.order_id CASCADE — 资金流水 (评估后建议也改 SET NULL，但本次不改，列入后续)
- platform_fees.order_id SET NULL — ✅ 已合理
- wallet_transactions.order_id SET NULL — ✅ 已合理
- trade_records.order_id SET NULL — ✅ 已合理
- trade_records.buyer_id/seller_id SET NULL — ✅ 已合理
- refunds.user_id SET NULL — ✅ 已合理
- disputes.initiator_id SET NULL — ✅ 已合理

### 2.3 前置数据检查 (执行迁移前必须运行)

```sql
-- ============================================
-- 前置检查 1: escrow_records 是否有孤儿买家
-- ============================================
SELECT COUNT(*) AS orphan_escrow_buyers
FROM public.escrow_records e
LEFT JOIN auth.users u ON e.buyer_id = u.id
WHERE e.buyer_id IS NOT NULL AND u.id IS NULL;

-- 预期: 0 (无孤儿)
-- 如果 > 0: 这些记录的 buyer_id 已经指向不存在的用户
--   处理: 迁移前先 SET NULL 这些 buyer_id
--   SQL: UPDATE public.escrow_records SET buyer_id = NULL
--        WHERE buyer_id IS NOT NULL
--        AND NOT EXISTS (SELECT 1 FROM auth.users WHERE id = escrow_records.buyer_id);

-- ============================================
-- 前置检查 2: escrow_records 是否有孤儿卖家
-- ============================================
SELECT COUNT(*) AS orphan_escrow_sellers
FROM public.escrow_records e
LEFT JOIN auth.users u ON e.seller_id = u.id
WHERE e.seller_id IS NOT NULL AND u.id IS NULL;

-- 预期: 0
-- 处理同上

-- ============================================
-- 前置检查 3: refunds 是否有孤儿订单
-- ============================================
SELECT COUNT(*) AS orphan_refund_orders
FROM public.refunds r
LEFT JOIN public.orders o ON r.order_id = o.id
WHERE r.order_id IS NOT NULL AND o.id IS NULL;

-- 预期: 0
-- 如果 > 0: 迁移前 SET NULL
--   SQL: UPDATE public.refunds SET order_id = NULL
--        WHERE order_id IS NOT NULL
--        AND NOT EXISTS (SELECT 1 FROM public.orders WHERE id = refunds.order_id);

-- ============================================
-- 前置检查 4: disputes 是否有孤儿订单
-- ============================================
SELECT COUNT(*) AS orphan_dispute_orders
FROM public.disputes d
LEFT JOIN public.orders o ON d.order_id = o.id
WHERE d.order_id IS NOT NULL AND o.id IS NULL;

-- 预期: 0
-- 处理同上

-- ============================================
-- 前置检查 5: 确认当前约束名称
-- ============================================
SELECT conname, conrelid::regclass AS table_name, confrelid::regclass AS ref_table
FROM pg_constraint
WHERE contype = 'f'
AND conrelid::regclass::text IN ('escrow_records', 'refunds', 'disputes')
ORDER BY conrelid::regclass::text;

-- 预期: 列出所有 FK 约束名称
-- 用于确认 DROP CONSTRAINT 时的约束名正确

-- ============================================
-- 前置检查 6: 检查是否有进行中的托管交易
-- ============================================
SELECT COUNT(*) AS active_escrows
FROM public.escrow_records
WHERE status IN ('held', 'pending');

-- 预期: 0 或很少
-- 如果 > 0: 建议等待这些交易完成后再执行迁移
-- ALTER CONSTRAINT 操作会短暂锁表，进行中的交易不受影响
```

### 2.4 迁移脚本

```sql
-- 0039_financial_fk_safety.sql
-- SH-006B: 金融记录 FK 安全加固
-- 优先级: P0
-- 可独立回滚: 是

BEGIN;

-- ============================================
-- 1. escrow_records: buyer_id CASCADE → SET NULL
-- ============================================

-- 1.1 查找并删除旧约束
ALTER TABLE public.escrow_records
    DROP CONSTRAINT IF EXISTS escrow_records_buyer_id_fkey;

-- 1.2 添加新约束
ALTER TABLE public.escrow_records
    ADD CONSTRAINT escrow_records_buyer_id_fkey
        FOREIGN KEY (buyer_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- ============================================
-- 2. escrow_records: seller_id CASCADE → SET NULL
-- ============================================

ALTER TABLE public.escrow_records
    DROP CONSTRAINT IF EXISTS escrow_records_seller_id_fkey;

ALTER TABLE public.escrow_records
    ADD CONSTRAINT escrow_records_seller_id_fkey
        FOREIGN KEY (seller_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- ============================================
-- 3. refunds: order_id CASCADE → SET NULL
-- ============================================

ALTER TABLE public.refunds
    DROP CONSTRAINT IF EXISTS refunds_order_id_fkey;

ALTER TABLE public.refunds
    ADD CONSTRAINT refunds_order_id_fkey
        FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL;

-- ============================================
-- 4. disputes: order_id CASCADE → SET NULL
-- ============================================

ALTER TABLE public.disputes
    DROP CONSTRAINT IF EXISTS disputes_order_id_fkey;

ALTER TABLE public.disputes
    ADD CONSTRAINT disputes_order_id_fkey
        FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL;

COMMIT;

-- ============================================
-- 迁移后注释
-- ============================================
COMMENT ON CONSTRAINT escrow_records_buyer_id_fkey ON public.escrow_records
    IS 'SH-006B: ON DELETE SET NULL — 买家删除账号时保留托管记录';
COMMENT ON CONSTRAINT escrow_records_seller_id_fkey ON public.escrow_records
    IS 'SH-006B: ON DELETE SET NULL — 卖家删除账号时保留托管记录';
COMMENT ON CONSTRAINT refunds_order_id_fkey ON public.refunds
    IS 'SH-006B: ON DELETE SET NULL — 订单删除时保留退款记录';
COMMENT ON CONSTRAINT disputes_order_id_fkey ON public.disputes
    IS 'SH-006B: ON DELETE SET NULL — 订单删除时保留争议记录';
```

### 2.5 验证 SQL

```sql
-- ============================================
-- 验证 1: 确认 ON DELETE 策略已更新
-- ============================================
SELECT
    conname AS constraint_name,
    conrelid::regclass AS table_name,
    a.attname AS column_name,
    confrelid::regclass AS ref_table,
    CASE confdeltype
        WHEN 'c' THEN 'CASCADE'
        WHEN 'n' THEN 'SET NULL'
        WHEN 'r' THEN 'RESTRICT'
        WHEN 'a' THEN 'NO ACTION'
        WHEN 'd' THEN 'SET DEFAULT'
    END AS on_delete
FROM pg_constraint c
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
WHERE c.contype = 'f'
AND conrelid::regclass::text IN ('escrow_records', 'refunds', 'disputes')
ORDER BY conrelid::regclass::text, a.attname;

-- 预期结果:
-- constraint_name             | table_name      | column_name | ref_table   | on_delete
-- escrow_records_buyer_id_fkey| escrow_records  | buyer_id    | users       | SET NULL
-- escrow_records_seller_id_fkey| escrow_records | seller_id   | users       | SET NULL
-- refunds_order_id_fkey       | refunds         | order_id    | orders      | SET NULL
-- disputes_order_id_fkey      | disputes        | order_id    | orders      | SET NULL

-- ============================================
-- 验证 2: 确认约束存在
-- ============================================
SELECT COUNT(*) AS expected_4_constraints
FROM pg_constraint
WHERE contype = 'f'
AND conname IN (
    'escrow_records_buyer_id_fkey',
    'escrow_records_seller_id_fkey',
    'refunds_order_id_fkey',
    'disputes_order_id_fkey'
);
-- 预期: 4

-- ============================================
-- 验证 3: 数据完整性未受影响
-- ============================================
SELECT COUNT(*) AS escrow_total FROM public.escrow_records;
SELECT COUNT(*) AS refunds_total FROM public.refunds;
SELECT COUNT(*) AS disputes_total FROM public.disputes;
-- 预期: 与迁移前一致
```

### 2.6 回滚方案

```sql
-- 回滚 0039: 恢复为 CASCADE (不推荐，仅紧急回滚用)
BEGIN;

ALTER TABLE public.escrow_records
    DROP CONSTRAINT IF EXISTS escrow_records_buyer_id_fkey;
ALTER TABLE public.escrow_records
    ADD CONSTRAINT escrow_records_buyer_id_fkey
        FOREIGN KEY (buyer_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public.escrow_records
    DROP CONSTRAINT IF EXISTS escrow_records_seller_id_fkey;
ALTER TABLE public.escrow_records
    ADD CONSTRAINT escrow_records_seller_id_fkey
        FOREIGN KEY (seller_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public.refunds
    DROP CONSTRAINT IF EXISTS refunds_order_id_fkey;
ALTER TABLE public.refunds
    ADD CONSTRAINT refunds_order_id_fkey
        FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;

ALTER TABLE public.disputes
    DROP CONSTRAINT IF EXISTS disputes_order_id_fkey;
ALTER TABLE public.disputes
    ADD CONSTRAINT disputes_order_id_fkey
        FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;

COMMIT;
```

### 2.7 影响范围分析

| 影响项 | 说明 |
|--------|------|
| 锁表 | ALTER CONSTRAINT 需要 AccessExclusiveLock，通常 < 1 秒 |
| 数据变更 | 无 — 仅修改约束元数据，不移动数据 |
| 应用代码 | 无 — 前端/RPC 不感知 ON DELETE 策略变更 |
| 触发器 | 无影响 |
| RLS | 无影响 |
| 性能 | FK 约束变更不影响查询性能 |
| 进行中交易 | 不受影响 — 约束变更不影响已有行的有效性 |

---

## 三、0040_profiles_auth_fk.sql

### 3.1 目标

1. 为 `profiles.id` 添加到 `auth.users(id)` 的 FK 约束 (DEFERRABLE)
2. 修复 `profiles.disabled_by` 和 `profiles.merchant_verified_by` 的 ON DELETE 策略
3. 修复 `live_sessions.host_id` 的 ON DELETE 策略

### 3.2 影响范围

| 表 | 列 | 当前状态 | 目标 | 原因 |
|----|-----|---------|------|------|
| profiles | id | 无 FK | FK → auth.users(id) ON DELETE CASCADE DEFERRABLE | 防止孤儿 profiles |
| profiles | disabled_by | FK 无 ON DELETE | FK → auth.users(id) ON DELETE SET NULL | 管理员删除时保留禁用记录 |
| profiles | merchant_verified_by | FK 无 ON DELETE | FK → auth.users(id) ON DELETE SET NULL | 审核人删除时保留验证记录 |
| live_sessions | host_id | FK NO ACTION | FK ON DELETE SET NULL | 主播删除时保留直播历史 |

### 3.3 前置数据检查

```sql
-- ============================================
-- 前置检查 1: profiles 孤儿记录 (profiles.id 在 auth.users 中不存在)
-- ============================================
SELECT COUNT(*) AS orphan_profiles
FROM public.profiles p
LEFT JOIN auth.users u ON p.id = u.id
WHERE u.id IS NULL;

-- 预期: 0
-- 如果 > 0: 添加 FK 会失败
--   处理方案:
--   方案 A (推荐): 删除孤儿 profiles
--     DELETE FROM public.profiles
--     WHERE id NOT IN (SELECT id FROM auth.users);
--   方案 B: 保留但无法添加 FK (放弃此迁移)
--   方案 C: 创建新用户 (不推荐 — 可能产生垃圾账号)

-- ============================================
-- 前置检查 2: 查看孤儿 profiles 详情 (如果检查 1 > 0)
-- ============================================
SELECT p.id, p.username, p.email, p.role, p.created_at
FROM public.profiles p
LEFT JOIN auth.users u ON p.id = u.id
WHERE u.id IS NULL
ORDER BY p.created_at DESC
LIMIT 20;

-- 用于评估是否可以安全删除

-- ============================================
-- 前置检查 3: 确认现有 FK 约束名称
-- ============================================
SELECT conname, conrelid::regclass AS table_name, a.attname AS column_name,
       CASE confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
            WHEN 'r' THEN 'RESTRICT' WHEN 'a' THEN 'NO ACTION' END AS on_delete
FROM pg_constraint c
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
WHERE c.contype = 'f'
AND (
    (conrelid::regclass::text = 'profiles' AND a.attname IN ('id', 'disabled_by', 'merchant_verified_by'))
    OR (conrelid::regclass::text = 'live_sessions' AND a.attname = 'host_id')
);

-- 预期: 列出现有约束名称和策略

-- ============================================
-- 前置检查 4: profiles 表是否有指向 auth.users 的 trigger
-- ============================================
SELECT tgname, tgtype, tgenabled
FROM pg_trigger
WHERE tgrelid = 'public.profiles'::regclass
AND NOT tgisinternal;

-- 预期: 应该有 handle_new_user trigger (在 auth.users INSERT 后创建 profiles)
-- 这是 DEFERRABLE 的原因 — trigger 在同一事务内执行

-- ============================================
-- 前置检查 5: live_sessions 孤儿主播
-- ============================================
SELECT COUNT(*) AS orphan_hosts
FROM public.live_sessions ls
LEFT JOIN auth.users u ON ls.host_id = u.id
WHERE ls.host_id IS NOT NULL AND u.id IS NULL;

-- 预期: 0
-- 如果 > 0: SET NULL 这些 host_id
```

### 3.4 迁移脚本

```sql
-- 0040_profiles_auth_fk.sql
-- SH-006B: profiles ↔ auth.users FK 完整性
-- 优先级: P1
-- 可独立回滚: 是
-- 前置条件: 0039 已执行 (建议但非必须)

BEGIN;

-- ============================================
-- 1. profiles.id → auth.users(id) FK (DEFERRABLE)
-- ============================================

-- 1.1 删除旧约束 (如果有)
ALTER TABLE public.profiles
    DROP CONSTRAINT IF EXISTS profiles_id_fkey;

-- 1.2 添加 DEFERRABLE FK
-- DEFERRABLE INITIALLY DEFERRED: 允许在同一事务内暂时违反 FK
-- 原因: handle_new_user trigger 在 auth.users INSERT 后创建 profiles
-- 非 DEFERRABLE FK 会在 trigger 执行前检查，导致失败
ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_id_fkey
        FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE
        DEFERRABLE INITIALLY DEFERRED;

-- ============================================
-- 2. profiles.disabled_by ON DELETE SET NULL
-- ============================================

ALTER TABLE public.profiles
    DROP CONSTRAINT IF EXISTS profiles_disabled_by_fkey;

ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_disabled_by_fkey
        FOREIGN KEY (disabled_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- ============================================
-- 3. profiles.merchant_verified_by ON DELETE SET NULL
-- ============================================

ALTER TABLE public.profiles
    DROP CONSTRAINT IF EXISTS profiles_merchant_verified_by_fkey;

ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_merchant_verified_by_fkey
        FOREIGN KEY (merchant_verified_by) REFERENCES auth.users(id) ON DELETE SET NULL;

-- ============================================
-- 4. live_sessions.host_id NO ACTION → SET NULL
-- ============================================

ALTER TABLE public.live_sessions
    DROP CONSTRAINT IF EXISTS live_sessions_host_id_fkey;

ALTER TABLE public.live_sessions
    ADD CONSTRAINT live_sessions_host_id_fkey
        FOREIGN KEY (host_id) REFERENCES auth.users(id) ON DELETE SET NULL;

COMMIT;

-- ============================================
-- 迁移后注释
-- ============================================
COMMENT ON CONSTRAINT profiles_id_fkey ON public.profiles
    IS 'SH-006B: DEFERRABLE INITIALLY DEFERRED — 允许 trigger 先执行';
COMMENT ON CONSTRAINT live_sessions_host_id_fkey ON public.live_sessions
    IS 'SH-006B: ON DELETE SET NULL — 主播删除时保留直播历史';
```

### 3.5 验证 SQL

```sql
-- ============================================
-- 验证 1: profiles.id FK 存在且 DEFERRABLE
-- ============================================
SELECT conname, condeferrable, condeferred,
       CASE confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' END AS on_delete
FROM pg_constraint
WHERE conname = 'profiles_id_fkey';

-- 预期:
-- conname           | condeferrable | condeferred | on_delete
-- profiles_id_fkey  | true          | true        | CASCADE

-- ============================================
-- 验证 2: 所有新 FK 约束存在
-- ============================================
SELECT conname,
       conrelid::regclass AS table_name,
       a.attname AS column_name,
       CASE confdeltype
           WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
           WHEN 'r' THEN 'RESTRICT' WHEN 'a' THEN 'NO ACTION'
       END AS on_delete
FROM pg_constraint c
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
WHERE c.contype = 'f'
AND conname IN (
    'profiles_id_fkey',
    'profiles_disabled_by_fkey',
    'profiles_merchant_verified_by_fkey',
    'live_sessions_host_id_fkey'
)
ORDER BY conname;

-- 预期:
-- profiles_id_fkey                | profiles     | id                     | CASCADE
-- profiles_disabled_by_fkey       | profiles     | disabled_by            | SET NULL
-- profiles_merchant_verified_by_fkey | profiles  | merchant_verified_by   | SET NULL
-- live_sessions_host_id_fkey      | live_sessions | host_id               | SET NULL

-- ============================================
-- 验证 3: 注册新用户测试 DEFERRABLE FK
-- ============================================
-- (需要通过 Supabase Auth API 注册测试用户)
-- 预期: 注册成功，profiles 行自动创建，无 FK 错误

-- ============================================
-- 验证 4: 数据完整性
-- ============================================
SELECT COUNT(*) AS profiles_total FROM public.profiles;
SELECT COUNT(*) AS live_sessions_total FROM public.live_sessions;
-- 预期: 与迁移前一致
```

### 3.6 回滚方案

```sql
-- 回滚 0040
BEGIN;

-- 移除 profiles.id FK
ALTER TABLE public.profiles
    DROP CONSTRAINT IF EXISTS profiles_id_fkey;

-- 恢复 disabled_by (恢复为无 ON DELETE 或 NO ACTION)
ALTER TABLE public.profiles
    DROP CONSTRAINT IF EXISTS profiles_disabled_by_fkey;
-- 注意: 恢复时需要知道原始约束定义。如果没有原始 FK，则不添加。

-- 恢复 merchant_verified_by
ALTER TABLE public.profiles
    DROP CONSTRAINT IF EXISTS profiles_merchant_verified_by_fkey;

-- 恢复 live_sessions.host_id (恢复为 NO ACTION)
ALTER TABLE public.live_sessions
    DROP CONSTRAINT IF EXISTS live_sessions_host_id_fkey;
-- 恢复原始约束 (如果有):
-- ALTER TABLE public.live_sessions
--     ADD CONSTRAINT live_sessions_host_id_fkey
--         FOREIGN KEY (host_id) REFERENCES auth.users(id);

COMMIT;
```

### 3.7 影响范围分析

| 影响项 | 说明 |
|--------|------|
| 锁表 | ALTER CONSTRAINT 需要 AccessExclusiveLock，profiles 表通常较小，< 1 秒 |
| 数据变更 | 无 — 仅修改约束元数据 |
| 新用户注册 | DEFERRABLE FK 确保不阻断 trigger |
| 用户删除 | 删除 auth.users 记录时，profiles 同步 CASCADE 删除 (与之前行为一致，之前无 FK 但 trigger 可能处理) |
| 应用代码 | 无 — 前端不感知 FK 变更 |
| 触发器 | handle_new_user trigger 不受影响 (DEFERRABLE) |
| RLS | 无影响 |
| 风险 | 如果有孤儿 profiles 数据，FK 添加会失败 → 前置检查必须通过 |

---

## 四、0041_cards_master_phase1.sql

### 4.1 目标

创建 `cards` 主表 (Phase 1)，定义与现有 `card_name` 字符串关联的映射关系。**不修改任何现有表**。

### 4.2 影响范围

| 操作 | 说明 |
|------|------|
| 新建表 | `public.cards` |
| 新建索引 | 3 个 |
| 新建 RLS | SELECT 对所有人开放 |
| 修改现有表 | **无** — 20+ 个使用 card_name 的表完全不动 |
| 修改现有数据 | **无** |

### 4.3 前置数据检查

```sql
-- ============================================
-- 前置检查 1: 确认 cards 表不存在
-- ============================================
SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'cards'
) AS cards_table_exists;

-- 预期: false (表不存在)
-- 如果 true: 需要先处理已存在的表

-- ============================================
-- 前置检查 2: 统计现有 card_name 唯一值数量
-- ============================================
-- 从 card_market 表统计 (主要卡牌来源)
SELECT COUNT(DISTINCT card_name) AS unique_card_names
FROM public.card_market;

-- 预期: 显示当前系统中有多少唯一卡牌名称
-- 这将是 cards 主表初始数据的来源

-- ============================================
-- 前置检查 3: 查看 card_market 表结构 (确认 card_name 列存在)
-- ============================================
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'card_market' AND table_schema = 'public'
ORDER BY ordinal_position;

-- 预期: 包含 card_name TEXT 列

-- ============================================
-- 前置检查 4: 查看现有 card_name 样本 (用于设计映射)
-- ============================================
SELECT DISTINCT card_name
FROM public.card_market
ORDER BY card_name
LIMIT 20;

-- 预期: 显示卡牌名称格式，用于确认 cards 主表字段设计
```

### 4.4 迁移脚本

```sql
-- 0041_cards_master_phase1.sql
-- SH-006B: cards 主表 Phase 1 (仅创建，不修改现有表)
-- 优先级: P2
-- 可独立回滚: 是
-- 前置条件: 无

BEGIN;

-- ============================================
-- 1. 创建 cards 主表
-- ============================================
CREATE TABLE IF NOT EXISTS public.cards (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,

    -- 卡牌标识
    card_name TEXT NOT NULL,           -- 中文名称 (与现有表 card_name 对应)
    card_name_en TEXT,                 -- 英文名称
    set_name TEXT,                     -- 系列/卡包名称
    set_code TEXT,                     -- 系列代码 (如 SV1M)
    card_number TEXT,                  -- 卡牌编号 (如 025/098)

    -- 卡牌属性
    rarity TEXT,                       -- 稀有度 (C/R/RR/CSR/UR...)
    image_url TEXT,                    -- 标准图片 URL
    category TEXT DEFAULT 'pokemon'
        CHECK (category IN ('pokemon', 'yugioh', 'mtg', 'onepiece', 'other')),

    -- 元数据
    metadata JSONB DEFAULT '{}'::jsonb,  -- 扩展字段 (PSA编号、BGS编号等)
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- 唯一约束: 同系列同编号的卡牌唯一
    UNIQUE(card_name, set_name, card_number)
);

-- ============================================
-- 2. 创建索引
-- ============================================
CREATE INDEX idx_cards_name ON public.cards(card_name);
CREATE INDEX idx_cards_category ON public.cards(category);
CREATE INDEX idx_cards_set ON public.cards(set_name);
CREATE INDEX idx_cards_name_set ON public.cards(card_name, set_name);

-- ============================================
-- 3. RLS 策略
-- ============================================
ALTER TABLE public.cards ENABLE ROW LEVEL SECURITY;

-- 所有人可读 (卡牌目录是公开信息)
CREATE POLICY "cards_read_all" ON public.cards
    FOR SELECT USING (true);

-- 无 INSERT/UPDATE/DELETE policy
-- → 仅 service_role (Edge Function / Dashboard) 可写入
-- → 普通用户无法修改卡牌目录

-- ============================================
-- 4. 更新时间触发器
-- ============================================
CREATE OR REPLACE FUNCTION public.update_cards_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cards_updated_at
    BEFORE UPDATE ON public.cards
    FOR EACH ROW
    EXECUTE FUNCTION public.update_cards_updated_at();

-- ============================================
-- 5. 映射视图 (可选: 方便查询 cards 与现有 card_market 的关系)
-- ============================================
-- 这个视图不修改任何现有表，仅提供查询便利
CREATE OR REPLACE VIEW public.v_card_mapping AS
SELECT
    c.id AS card_id,
    c.card_name,
    c.set_name,
    c.rarity,
    cm.id AS market_id,
    cm.final_price,
    cm.source_type
FROM public.cards c
LEFT JOIN public.card_market cm ON cm.card_name = c.card_name;
-- 注意: 此视图用 card_name 字符串 JOIN，不是 UUID FK
-- Phase 2 将在 card_market 添加 card_id UUID 列后改为 FK JOIN

COMMIT;

-- ============================================
-- 迁移后注释
-- ============================================
COMMENT ON TABLE public.cards IS
    'SH-006B Phase 1: 卡牌主表。当前阶段不修改现有表的 card_name 字符串关联。Phase 2 将在 card_market 添加 card_id UUID 列。';
COMMENT ON VIEW public.v_card_mapping IS
    'SH-006B Phase 1: cards ↔ card_market 映射视图 (基于 card_name 字符串 JOIN，非 UUID FK)';
```

### 4.5 验证 SQL

```sql
-- ============================================
-- 验证 1: cards 表存在
-- ============================================
SELECT EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'cards'
) AS cards_table_created;
-- 预期: true

-- ============================================
-- 验证 2: 索引存在
-- ============================================
SELECT indexname FROM pg_indexes
WHERE tablename = 'cards' AND schemaname = 'public';
-- 预期: idx_cards_name, idx_cards_category, idx_cards_set, idx_cards_name_set

-- ============================================
-- 验证 3: RLS 已启用
-- ============================================
SELECT relrowsecurity
FROM pg_class
WHERE relname = 'cards' AND relnamespace = 'public'::regnamespace;
-- 预期: true

-- ============================================
-- 验证 4: SELECT 策略存在
-- ============================================
SELECT polname, polcmd, polqual
FROM pg_policy
WHERE polrelid = 'public.cards'::regclass;
-- 预期: cards_read_all, SELECT, 'true' (允许所有人)

-- ============================================
-- 验证 5: 普通 CRUD 测试
-- ============================================
-- 5.1 匿名用户可读
SELECT * FROM public.cards LIMIT 1;
-- 预期: 0 rows (空表) 或正常返回

-- 5.2 普通用户不可写 (通过 anon key)
-- INSERT INTO public.cards (card_name) VALUES ('测试');
-- 预期: RLS 拒绝 (无 INSERT policy)

-- 5.3 service_role 可写 (通过 Dashboard 或 Edge Function)
-- INSERT INTO public.cards (card_name, set_name, rarity, category)
-- VALUES ('皮卡丘', 'SV1M', 'C', 'pokemon');
-- 预期: 成功

-- ============================================
-- 验证 6: 视图存在
-- ============================================
SELECT EXISTS (
    SELECT 1 FROM information_schema.views
    WHERE table_schema = 'public' AND table_name = 'v_card_mapping'
) AS mapping_view_created;
-- 预期: true

-- ============================================
-- 验证 7: 触发器存在
-- ============================================
SELECT tgname, tgenabled
FROM pg_trigger
WHERE tgrelid = 'public.cards'::regclass
AND NOT tgisinternal;
-- 预期: trg_cards_updated_at, enabled
```

### 4.6 回滚方案

```sql
-- 回滚 0041 (完全安全 — 不影响任何现有表)
BEGIN;

DROP VIEW IF EXISTS public.v_card_mapping;
DROP TRIGGER IF EXISTS trg_cards_updated_at ON public.cards;
DROP FUNCTION IF EXISTS public.update_cards_updated_at();
DROP TABLE IF EXISTS public.cards CASCADE;

COMMIT;
-- 注意: 如果 cards 表已有数据，回滚会删除这些数据
-- 建议: 回滚前先导出数据 (SELECT * INTO backup_cards FROM public.cards)
```

### 4.7 影响范围分析

| 影响项 | 说明 |
|--------|------|
| 新建表 | public.cards — 不影响现有表 |
| 新建视图 | public.v_card_mapping — 只读视图，不影响写入 |
| 新建触发器 | 仅作用于 cards 表 |
| 现有表 | **完全不动** — 20+ 个 card_name 字符串关联表不受影响 |
| 现有数据 | **完全不动** |
| 应用代码 | **无需修改** — cards 表是可选的，前端不依赖 |
| RLS | 仅 cards 表新增 RLS，不影响其他表 |
| 性能 | 新表+索引占少量空间，对现有查询无影响 |
| 定价引擎 | 不受影响 — card_market 表不变 |
| 触发器链 | 不受影响 — 不添加任何指向现有表的 FK |

### 4.8 后续 Phase 2/3 路线 (不在本次范围)

| Phase | 内容 | 时机 |
|-------|------|------|
| Phase 2 | card_market 表新增 `card_id UUID REFERENCES cards(id)` 列，逐步回填 | Beta 后 |
| Phase 3 | 其他表逐步新增 card_id，最终废弃 card_name 字符串关联 | 正式发布后 |

---

## 五、执行顺序与依赖

```
0039_financial_fk_safety.sql (P0)
    │  无依赖，可独立执行
    │  建议在低峰期执行 (ALTER CONSTRAINT 短暂锁表)
    ▼
0040_profiles_auth_fk.sql (P1)
    │  无硬依赖，但建议 0039 先执行
    │  必须通过前置检查 (孤儿 profiles = 0)
    ▼
0041_cards_master_phase1.sql (P2)
    无依赖，任何时候可执行
    纯新增，零风险
```

**建议执行时间**:
- 0039: 0038 (SH-003B) 执行后，低峰期
- 0040: 0039 验证通过后
- 0041: 任意时间 (可与其他迁移并行)

---

## 六、总结矩阵

| 迁移 | 优先级 | 改动表数 | 改动类型 | 锁表时间 | 数据风险 | 回滚难度 |
|------|--------|---------|---------|---------|---------|---------|
| 0039 | P0 | 3 | FK 策略修改 | < 1s/表 | 无 | 简单 (恢复 CASCADE) |
| 0040 | P1 | 2 | 新增 FK + 策略修改 | < 1s/表 | 低 (需无孤儿) | 简单 (DROP CONSTRAINT) |
| 0041 | P2 | 0 (新建 1) | 新建表 | 0 | 无 | 极简 (DROP TABLE) |

---

## 七、与 SH-003B 的关联

| 关联点 | 说明 |
|--------|------|
| 0038 (SH-003B) 中的 admin_audit_logs 表 | 其 admin_id REFERENCES auth.users(id) ON DELETE SET NULL — 与 0039 原则一致 |
| 0038 中的 profiles RLS 加固 | 与 0040 的 profiles FK 互补 — RLS 控制访问，FK 控制完整性 |
| admins 表保留只读 | 0039/0040/0041 均不修改 admins 表 — 与 SH-003B Phase 4 一致 |

---

*本文件为 SH-006B 最终迁移计划，等待王总审核后进入实施阶段。*
