# CR-0107-04F-C — Authoritative 0034 Migration Plan

**项目**: `D:\codex\cardrealm\card-app`
**状态**: ⏳ WAITING CEO REVIEW（仅方案，未修改任何文件）
**上游**: CR-0107-04F-A（重复审计）已完成 · CR-0107-04F-B（live RPC 调查）已完成但凭证阻断

---

## 0. 约束与范围声明

| 禁止项 | 是否触碰 |
|---|---|
| 修改 SQL | ❌ 否 |
| git mv | ❌ 否 |
| archive | ❌ 否 |
| migration repair | ❌ 否 |
| db push | ❌ 否 |
| commit | ❌ 否 |
| push | ❌ 否 |

**仅生成方案**。本文件所有"步骤"均为未来可执行动作描述，需 CEO 另行逐条授权。

### 0.1 已确认前提（来自本任务输入）
- `0034_tiered_market_system.sql` = **结构真相源**（4 表 / 5 视图 / 11 索引 / 8 RLS / 8 函数 + 一堆 ALTER/DROP 演进）。
- 线上 7 个 RPC 为 **混合状态**：
  - `create_sealed_product_order` = **tiered 版**（已确认）
  - `create_merchandise_order` = **tiered 版**（已确认）
  - 部分 `admin_*` / `cancel_*` RPC = **修复分支（public_prefix 变体）**（已确认"部分"，具体哪几个待 live 查询钉死）

---

## 1. 需保留的 tiered 对象清单（KEEP 全部）

### 1.1 Tables（4）— `CREATE TABLE IF NOT EXISTS`
| 表 | 行号 | 备注 |
|---|---|---|
| `sealed_products` | 18 | 一级市场盲盒商品 |
| `sealed_product_orders` | 115 | 一级市场订单 |
| `merchandise` | 168 | 周边商品 |
| `merchandise_orders` | 239 | 周边订单 |

### 1.2 Views（5）— `CREATE OR REPLACE VIEW`
| 视图 | 行号 |
|---|---|
| `three_tier_product_catalog` | 323 |
| `primary_market_store` | 415 |
| `secondary_market_list` | 470 |
| `merchandise_store` | 519 |
| `platform_store_list` | 1072 |

### 1.3 Indexes（11）— `CREATE INDEX IF NOT EXISTS`
```
idx_sp_type_status      (1160)   sealed_products
idx_sp_brand_series     (1161)   sealed_products
idx_sp_sku              (1162)   sealed_products
idx_sp_pre_order        (1163)   sealed_products
idx_spo_user_status     (1166)   sealed_product_orders
idx_spo_product         (1167)   sealed_product_orders
idx_spo_order_no        (1168)   sealed_product_orders
idx_m_type_status       (1171)   merchandise
idx_m_sku               (1172)   merchandise
idx_mo_user_status      (1175)   merchandise_orders
idx_mo_product          (1176)   merchandise_orders
```

### 1.4 RLS Policies（8）— `ENABLE ROW LEVEL SECURITY` + `CREATE POLICY`
| Policy | 表 | 行号 |
|---|---|---|
| `read_sealed_products` | sealed_products | 1135 |
| `write_sealed_products_rpc` | sealed_products | 1136 |
| `read_own_sealed_orders` | sealed_product_orders | 1140 |
| `write_sealed_orders_rpc` | sealed_product_orders | 1142 |
| `read_merchandise` | merchandise | 1146 |
| `write_merchandise_rpc` | merchandise | 1147 |
| `read_own_merch_orders` | merchandise_orders | 1151 |
| `write_merch_orders_rpc` | merchandise_orders | 1153 |

> 全部 `FOR ALL USING (auth.uid() = ... )` owner-scoped（与 SH-003 统一认证一致），auth 不在此文件处理。

### 1.5 Functions（8）— `CREATE OR REPLACE FUNCTION`
| 函数 | 行号 | 是否 7 RPC 之一 | 冲突源 |
|---|---|---|---|
| `admin_create_sealed_product` | 560 | 否 | **仅 tiered 有，修复分支不含 → 恒取 tiered** |
| `admin_update_sealed_product` | 625 | ✅ | tiered + public_prefix |
| `create_sealed_product_order` | 689 | ✅ | tiered + public_prefix |
| `cancel_sealed_product_order` | 747 | ✅ | tiered + public_prefix |
| `admin_confirm_sealed_order` | 776 | ✅ | tiered + public_prefix |
| `admin_create_merchandise` | 822 | ✅ | tiered + public_prefix |
| `admin_update_merchandise` | 869 | ✅ | tiered + public_prefix |
| `create_merchandise_order` | 920 | ✅ | tiered + public_prefix |

### 1.6 ALTER / DROP 演进（结构真相的一部分，必须保留）
- 向 `card_market` / `user_collections` / `platform_cards` / `ai_scan_logs` / `scan_history` / `consignments` 追加 `market_tier` 列（`DEFAULT 'secondary'`）。
- `platform_cards_source_check` 约束重建（313-314）。
- **删除** tiktok / live 子系统：`live_sync_items`、`live_sessions`、`live_sessions_overview`、`market_list_with_seller`、`tiktok_shop_*`、`sync_logs`、`price_push_queue`、`live_selection_*` 等表/视图/函数/列（1025-1067）。
- 这些 `ALTER ... ADD COLUMN IF EXISTS` / `DROP ... IF EXISTS` 已幂等，合并后保持。

---

## 2. 7 个 RPC 的最终来源 = live DB definition

### 2.1 每 RPC 来源映射表
| # | RPC | live 来源（最终） | 状态 |
|---|---|---|---|
| 1 | `admin_update_sealed_product` | 待 live 查询钉死 | **TBD** |
| 2 | `create_sealed_product_order` | **tiered 版** | ✅ 已确认 |
| 3 | `cancel_sealed_product_order` | 待 live 查询钉死 | **TBD** |
| 4 | `admin_confirm_sealed_order` | 待 live 查询钉死 | **TBD** |
| 5 | `admin_create_merchandise` | 待 live 查询钉死 | **TBD** |
| 6 | `admin_update_merchandise` | 待 live 查询钉死 | **TBD** |
| 7 | `create_merchandise_order` | **tiered 版** | ✅ 已确认 |

> 用户确认"部分 admin/cancel RPC = 修复分支"，故 #1/#3/#4/#5/#6 中至少有一个（至多五个）取 public_prefix 变体。精确归属须由 §2.3 的 live 查询决定，**不可凭文件名猜测**。

### 2.2 两变体的真实差异（已用 diff 验证，非表面）
对 `admin_update_sealed_product` 做归一化 diff（去注释 + 去前导空格 + 去 `public.` 前缀）仍有 **220 行差异**，核心区别：

| 维度 | tiered 变体 | 修复分支（public_prefix） |
|---|---|---|
| 指令 | 含 `#variable_conflict use_column` | **无** |
| 序号变量 | `v_order_no_val` | `v_order_no`（无 `_val`） |
| 函数注释 | 含 `COMMENT ON FUNCTION ... IS` | **无** |
| UUID 调用 | `extensions.gen_random_uuid()` | `gen_random_uuid()`（无 `extensions.`） |
| DECLARE 变量 | 多（如 `v_sku TEXT`） | 少（删减变量） |

→ 这是**行为级差异**（如 `#variable_conflict` 解决变量/列名冲突；`extensions.` 模式限定影响 search_path 解析），**绝不可随意选一**，必须逐 RPC 对齐 live 真身。

### 2.3 判定规则（body 级，已验证可用）
对每个 7 RPC，执行 CR-0107-04F-B §2 的 `pg_get_functiondef(oid)` 查询，然后比对：

- live 体含 **`#variable_conflict use_column`** 或 **`v_order_no_val`** 或 **`extensions.gen_random_uuid()`** 或 **`COMMENT ON FUNCTION ... IS`** → 来源 = **tiered**
- live 体用 **`v_order_no`**（无 `_val`）且 **`gen_random_uuid()`**（无 `extensions.`）且无 `#variable_conflict` → 来源 = **修复分支（public_prefix）**

> 注：`public.` 模式限定**不是**判别符 —— 两变体均大量使用（tiered 甚至更多），已在 04F-C 实测排除。

---

## 3. 单一 authoritative migration 文件设计

### 3.1 组成方式
```
authoritative_0034 = 完整 tiered 内容
                     − 7 个 RPC 的 tiered 函数体
                     + 按 §2.1 来源表逐 RPC 填入 live 对应变体体
```
- `admin_create_sealed_product`：恒取 tiered（无冲突，保留）。
- 其余 8 个函数 + 4 表 + 5 视图 + 11 索引 + 8 策略 + 全部 ALTER/DROP：原样来自 tiered。

### 3.2 产出对象集（单文件）
- 4 表 / 5 视图 / 11 索引 / 8 RLS 策略 / 8 函数（7 RPC 按 live 对齐 + `admin_create_sealed_product`）
- 幂等性保持（原文件已全用 `IF NOT EXISTS` / `IF EXISTS` / `DROP ... IF EXISTS`）

### 3.3 文件名（衔接 CR-0107-04F path B 合成时间戳）
```
supabase/migrations/20240101000034_tiered_market_system_authoritative.sql
```
> 04F path B 将 `00XX` 序号格式重命名为 `202401010000XX` 合成时间戳以被 CLI 识别。本文件将原本 4 个 `0034_*` 合并为 **1 个** 权威 version `20240101000034`，消除 version 碰撞。

### 3.4 文件内部顺序
严格沿用 tiered 现有顺序：建表 → ALTER 演进 → 视图 → 函数（含 7 RPC 覆盖） → DROP tiktok/live → 末视图 → RLS/策略 → 索引 → COMMENT。仅替换 7 RPC 函数体，不改变整体编排。

---

## 4. 三个旧文件归档设计（NOT 执行）

### 4.1 待归档文件
- `0034_fix_batch1.sql`（3 RPC 子集）
- `0034_fix_batch2.sql`（4 RPC 子集）
- `0034_fix_public_prefix.sql`（7 RPC 合并收口版 = 修复分支）

### 4.2 归档动作（未来，需 04F 授权）
```bash
mkdir -p supabase/migrations/_archive/0034_redundant
git mv 0034_fix_batch1.sql           supabase/migrations/_archive/0034_redundant/
git mv 0034_fix_batch2.sql           supabase/migrations/_archive/0034_redundant/
git mv 0034_fix_public_prefix.sql    supabase/migrations/_archive/0034_redundant/
```

### 4.3 为何必须移出 `migrations/`
- 三者前缀均为 `0034` → 与权威文件 version 碰撞。
- 含重复的 `CREATE OR REPLACE FUNCTION`（7 RPC）→ 留原地会使 `supabase migration list` / `db push` 出现重复 version、幂等重放风险。
- 移入 `_archive/`（非 `migrations/` 子目录）后不被 CLI 扫描，保留历史溯源。

---

## 5. 验证：db reset 后结构 & RPC == 生产（未来步骤）

> ⚠️ `supabase db reset` 当前**明确禁止**，仅作为未来授权步骤描述。

### 5.1 前置（未来，需分别授权）
1. 取得有效 Supabase PAT 或 DB URL（解封 04F-B live 审计）
2. 执行 04F path B：00XX→202401010000XX 重命名 + `migration repair --status applied`（59 version）
3. 构建并放置 §3 权威文件
4. 归档 §4 三文件

### 5.2 结构校验
```sql
-- reset DB 与 live 生产各跑一次，比对 schema-only dump 差异
pg_dump --schema-only --no-owner --no-privileges -h <host> -d postgres
```
期望：本子系统（sealed_products / merchandise / 三层视图 / 索引 / 策略）**零结构差异**。

### 5.3 RPC 校验（7 个）
```sql
SELECT pg_get_functiondef(oid)
FROM pg_proc WHERE proname IN (
  'admin_update_sealed_product','create_sealed_product_order',
  'cancel_sealed_product_order','admin_confirm_sealed_order',
  'admin_create_merchandise','admin_update_merchandise','create_merchandise_order'
);
```
- reset DB 的 7 体 与 live 生产 的 7 体 **逐字节一致**。
- 重点核对：`v_order_no_val` vs `v_order_no`、`#variable_conflict` 存在性、`COMMENT ON` 存在性、`extensions.` 前缀 —— 必须与 §2.1 来源表吻合。

### 5.4 验收标准
- ✅ reset DB 的 sealed/merchandise schema == 生产
- ✅ 7 RPC 函数体 == 生产 live 体
- ✅ `supabase migration list` 显示 `20240101000034` 权威版为 applied，无 0034 孤儿漂移

---

## 6. 未来执行序列（全部需逐条授权）
1. 获取有效 Supabase 凭证 → 解封 04F-B live 审计
2. 跑 04F-B 查询 → 按 §2.3 规则填妥 §2.1 每 RPC 来源
3. 按 §3 构建单权威文件（7 RPC 体按 live 对齐）
4. 按 §4 `git mv` 三冗余文件至 `_archive/0034_redundant/`
5. 按 04F path B 重命名余下 00XX→202401010000XX + `migration repair`（59 version）
6. `supabase migration list` 验收
7. （可选、授权后）`db reset` + §5 验证

---

## 7. 约束合规性确认
全部禁止项（修改 SQL / git mv / archive / repair / db push / commit / push）**本次均未执行**。本文件为纯方案文档。

---

**状态**: ⏳ WAITING CEO REVIEW
