# CR-0107-04F-A · Migration 0034 重复审计

**审计对象**：`D:\codex\cardrealm\card-app\supabase\migrations\` 下全部 `0034_*.sql`
**审计类型**：仅审计重复 migration（只读）
**日期**：2026-08-05
**状态**：⏳ WAITING CEO REVIEW

---

## 0. 审计边界与约束（本次严格遵守）

| 禁止操作 | 是否触碰 |
|---|---|
| 删除文件 | ❌ 否 |
| rename | ❌ 否 |
| migration repair | ❌ 否 |
| db push | ❌ 否 |
| commit | ❌ 否 |
| push | ❌ 否 |

> 本报告仅做**内容审计 + 处理建议**。所有"保留 / 归档 / 合并"动作均为**提案**，需 CEO 评审后另行授权执行。

---

## 1. 发现：4 个 0034 文件清单（文件名 / 大小 / hash）

| # | 文件名 | 大小 (bytes) | SHA-256 |
|---|---|---|---|
| 1 | `0034_tiered_market_system.sql` | 56,230 | `b37919a0eab8d049f3f7e50507d781b8955cf0a3098a8b3cb4bc742d07c0f90a` |
| 2 | `0034_fix_public_prefix.sql` | 16,376 | `32bf0444b676b8a9724774ca8ac493f89faa7c1d8d374a7dad4ca9828d6c744f` |
| 3 | `0034_fix_batch2.sql` | 9,093 | `f3e04dba2ae8f1016d68410c35c098b34cba255c8de7ba4d60b1184c4ca10e25` |
| 4 | `0034_fix_batch1.sql` | 7,282 | `1fab81ae879cf3a470085a69c8e7d074b781a8a73e9da5f17e38bd6a6538adfb` |

**公共属性**：
- 4 个文件 mtime 均为 `Jul 12 00:22`，且**同一次 commit** 入库：`be78528 "0034: 分层卡牌经济系统 — 三层市场体系完整迁移"`。
- 4 个文件均被 git 跟踪（已提交，工作区干净）。
- 4 个文件名第一段均为 `0034` → **Migration 版本号冲突**：Supabase 以首个 `_` 前的内容作 version，4 份共享 version `0034`，这正是 CR-0107-04F 所指的"0034×4 重复"。

---

## 2. 内容对比结论（三个核心问题）

### Q1. 是否完全重复？ → **否**
4 个 sha256 互不相同，非字节级重复。即使 `0034_fix_batch1.sql`（3 个函数）被 `0034_fix_public_prefix.sql` 包含，二者也**不是字节相同**——public_prefix 的函数体有细微差异（见 §4），且 public_prefix 多出 4 个函数。

### Q2. 是否不同阶段演进？ → **是（重叠式演进 / 修复波次）**
证据链：
- 命名语义：`tiered_market_system`（基础系统）→ `fix_batch1` / `fix_batch2`（增量修复批次）→ `fix_public_prefix`（合并 + `public.` 限定的收口版）。
- `public.` 限定符计数数学印证：`public_prefix`=65 ≈ `batch1`(32) + `batch2`(33)，证明 public_prefix 是 batch1∪batch2 的**函数并集**收口版。
- 逻辑上：tiered 先建系统，batch1/batch2 是分批的 RPC 修复，public_prefix 把两批合并并补 `public.` 限定。

### Q3. 是否有依赖关系？ → **是（硬依赖）**
- batch1 / batch2 / public_prefix 中的 7 个 RPC 函数，全部操作 `sealed_products` / `sealed_product_orders` / `merchandise` / `merchandise_orders`——**这 4 张表仅由 `0034_tiered_market_system.sql` 创建**（全库 grep 确认，无其他 migration 创建）。
- 因此 **tiered 必须先于其余 3 份执行**；若将来做时间戳重命名，tiered 必须取最早时间戳。
- 小文件之间：`public_prefix ⊇ batch1 ∪ batch2`，无相互依赖，仅集合包含。
- 后续 migration 引用：仅 `0043_admin_rpc_group_d_disable.sql` 按**函数名**对这些 RPC 做 `REVOKE ALL` / 置 `DEPRECATED` COMMENT（动态 `pg_proc` 查找，不绑定来源文件）。→ 归档小文件不影响 0043，**前提是 tiered 保留**（tiered 仍定义全部 8 个函数）。

---

## 3. 对象清单交叉分析（全库 grep）

### 3.1 结构型对象（表 / 视图 / 索引 / RLS）——**仅存在于 tiered**
| 对象类别 | 数量 | 所在文件 |
|---|---|---|
| `CREATE TABLE` | 4（sealed_products, sealed_product_orders, merchandise, merchandise_orders） | 仅 tiered |
| `CREATE VIEW` | 5（three_tier_product_catalog, primary_market_store, secondary_market_list, merchandise_store, platform_store_list） | 仅 tiered |
| `CREATE INDEX` | 17 | 仅 tiered |
| `CREATE POLICY` (RLS) | ~13（含 `write_*_rpc FOR ALL USING(true)` 宽松策略） | 仅 tiered |
| `ALTER TABLE` | 多处（market_tier 列、DROP 旧列/约束等） | 仅 tiered |

→ **tiered 是唯一承载"结构 DDL"的文件**。其余 3 份为零结构新增。

### 3.2 函数定义分布（全库 8 个相关函数）
| 函数 | 定义位置 |
|---|---|
| `admin_create_sealed_product` | 仅 tiered（1×） |
| `admin_update_sealed_product` | tiered + batch1 + public_prefix（3×） |
| `create_sealed_product_order` | tiered + batch1 + public_prefix（3×） |
| `cancel_sealed_product_order` | tiered + batch1 + public_prefix（3×） |
| `admin_confirm_sealed_order` | tiered + batch2 + public_prefix（3×） |
| `admin_create_merchandise` | tiered + batch2 + public_prefix（3×） |
| `admin_update_merchandise` | tiered + batch2 + public_prefix（3×） |
| `create_merchandise_order` | tiered + batch2 + public_prefix（3×） |

→ 7 个 RPC 函数被**重复定义 3 次**（tiered 一次 + 修复批次一次 + public_prefix 收口一次）；`admin_create_sealed_product` 仅 tiered 定义一次。
→ **3 个小文件未引入任何新对象**，仅对 tiered 已定义的 7 个 RPC 做了"再定义"。

---

## 4. 关键差异：同名函数不同体（合并前必须澄清的风险）

对 `admin_update_sealed_product` / `create_sealed_product_order` 逐体比对（剥离 `public.` 与注释、缩进归一后）：

| 维度 | `tiered_market_system` 版 | `batch1` / `batch2` / `public_prefix` 版 |
|---|---|---|
| `COMMENT ON FUNCTION` | ✅ 有（每个 RPC 均带 COMMENT） | ❌ 无 |
| 内部变量命名 | `v_order_no_val` | `v_order_no` |
| RETURN 列命名 | 受 `v_order_no_val` 影响 | 受 `v_order_no` 影响 |
| 函数逻辑本质 | 同 | 同（仅命名/注释差异） |

**结论**：同名函数存在**真实（虽轻微）的体差异**——不是纯格式差异。`CREATE OR REPLACE FUNCTION` 场景下，**最后应用的一份生效**。因此"现场（live）数据库当前用的是哪一版函数体"存在不确定性（见 §5）。

---

## 5. 现场（live）状态不确定性 —— 关键风险

1. **远程 `schema_migrations` 无 `0034` version**（CR-0107-04A 结论：远程仅 5 个时间戳孤儿 version）。→ 这 4 份**从未被 CLI 跟踪**，是手动（Dashboard SQL Editor）或一次性导入应用的本地产物。
2. **`supabase-full-setup.sql` 不含此子系统**（grep 确认：无 sealed_products / 无 7 个 RPC / 无 tiered 视图）。→ 现场该子系统的 schema **来自这 4 份 0034 文件**，而非 full-setup。
3. 因 7 个 RPC 被 `CREATE OR REPLACE` 多次：
   - 若 4 份曾按文件名顺序手动全量应用 → **public_prefix 最后生效** → 现场用 `v_order_no` 版（无 COMMENT）。
   - 若仅应用了 tiered → 现场用 `v_order_no_val` + COMMENT 版。
   - **当前无法从文件本身判定现场是哪种**。

> ⚠️ **合并 / 归档前强制前置动作**：必须对 live DB 执行 `SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname='admin_update_sealed_product';`（及其余 6 个 RPC），确认现场实际函数体，再决定以哪一版为权威并入 tiered。**不可凭文件猜测覆盖现场函数**。

---

## 6. 处理建议（提案 · 本次不执行）

### ✅ 保留（KEEP · 作为唯一权威 0034）
**`0034_tiered_market_system.sql`**
- 理由：全库唯一含结构 DDL（4 表 / 5 视图 / 17 索引 / ~13 RLS 策略 / ALTER）+ 全 8 函数的文件。它是该子系统的"真相源"。
- 后续（CR-0107-04F path B）将其重命名为时间戳版（如 `20240101000034_tiered_market_system.sql`）并 `migration repair --status applied`，使 CLI 正确跟踪单一 version `0034`。

### 🗄 归档（ARCHIVE · 不删除、不原地 rename）
**`0034_fix_batch1.sql` / `0034_fix_batch2.sql` / `0034_fix_public_prefix.sql`**
- 理由：三份都是 tiered 已定义 7 个 RPC 的**冗余重定义**，未引入新对象；public_prefix 仅是 batch1∪batch2 的收口。
- 归档方式（推荐保留 git 历史）：用 `git mv` 移入 `supabase/migrations/_archive/0034_redundant/`，**不删除**。
- 安全前提：归档不影响 0043（按名 REVOKE）与任何调用方，因为 tiered 仍定义全部函数。

### 🔧 归档前强制合并步骤（消除 §4/§5 风险）
1. 对 live DB 取 7 个 RPC 的 `pg_get_functiondef`，确认真实体。
2. 将 live 正确体并入 `0034_tiered_market_system.sql`（保留 tiered 的结构 DDL + `COMMENT ON`）；如需采用 public_prefix 的 `v_order_no` 命名，连同注释一并吸纳。
3. 校验合并后 tiered 仍能独立重建现场全部 4 表 / 5 视图 / 8 函数 / RLS / 索引（幂等 `CREATE ... IF NOT EXISTS` / `CREATE OR REPLACE`）。
4. 上述校验通过后再执行归档。

### 🔗 与 CR-0107-04F 的衔接
本审计支撑 04F "归并 0034×4" 指令：将 4 份收敛为**单一权威 0034**（tiered 内容 + live 正确 RPC 体），其余 3 份归档；随后按 04F path B 做时间戳重命名 + repair，使 `migration list` 的 Local/Remote 对齐。

---

## 7. 提案命令（供 CEO 评审后执行 · 本次未运行）

```bash
# (1) 校验 live 实际函数体（只读，确认权威版本）—— 需可用 DB 连接
psql "$DATABASE_URL" -c "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname IN ('admin_update_sealed_product','create_sealed_product_order','cancel_sealed_product_order','admin_confirm_sealed_order','admin_create_merchandise','admin_update_merchandise','create_merchandise_order');"

# (2) 归档冗余 3 份（git mv 保留历史，不删除）
mkdir -p supabase/migrations/_archive/0034_redundant
git mv supabase/migrations/0034_fix_batch1.sql        supabase/migrations/_archive/0034_redundant/
git mv supabase/migrations/0034_fix_batch2.sql        supabase/migrations/_archive/0034_redundant/
git mv supabase/migrations/0034_fix_public_prefix.sql supabase/migrations/_archive/0034_redundant/

# (3) （后续，CR-0107-04F path B）对唯一权威 0034 做时间戳重命名 + repair
#     npx supabase migration repair --status applied --linked 20240101000034
```

> 注：步骤 (2)(3) 及"合并 live 正确 RPC 体进 tiered"均**不在本次审计范围内**，须 CEO 单独授权。

---

## 8. 一句话结论

4 份 `0034_*.sql` **非完全重复**，而是"基础系统 (tiered) + 三波 RPC 重定义 (batch1/batch2/public_prefix)"的**版本号冲突（共享 version 0034）+ 重叠式冗余**；其中 tiered 是唯一结构真相源，其余 3 份为可被归档的冗余 RPC 重定义。**合并 / 归档前必须先对 live DB 校验 7 个 RPC 的实际函数体**，以 tiered 为权威、吸纳现场正确体，避免覆盖线上函数签名。

**状态：⏳ WAITING CEO REVIEW**
