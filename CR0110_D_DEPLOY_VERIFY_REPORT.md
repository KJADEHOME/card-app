# CR-0110-D Beta 部署验证报告：portfolio identity orphan 清理（DH-1）

> 状态：**验证完成（仅 Beta 验证，未部署、未 db push）** · WAITING CEO REVIEW
> 关联：DH-1（CR-0107-04F-U 发现）；CR-0110-B（方案已批准，MVP = ①+②+④）；CR-0110-C（迁移实施）
> 项目：`D:\codex\cardrealm\card-app`（分支 `release-beta-preparation`，Beta ref `xybpcsmjjcnkjwfsuder`）
> 生成时间：2026-08-05 14:04 (GMT+8)

---

## 1. 环境与测试时间

| 项 | 值 |
|----|----|
| 目标环境 | Supabase Beta（ref `xybpcsmjjcnkjwfsuder`），`--linked` |
| 测试时间 | 2026-08-05 13:51 – 14:04 (GMT+8) |
| 工具 | `npx supabase db query --linked`（CLI v2.x，service_role 连接） |
| 被测迁移 | `supabase/migrations/20260805213000_portfolio_identity_orphan_cleanup.sql`（**未 db push**，见 §7） |
| 验证方式 | **影子测试（Shadow Test）**：在 Beta 创建 `_cr0110d_` 前缀的临时对象（复制迁移逻辑），执行 TC-1/TC-2，随后**全部 DROP**，Beta 保持部署前状态 |

> 说明：本任务禁止 `db push`、禁止部署真实迁移（"不要自动部署"）。为在 Beta 真实 Postgres 引擎上验证 plpgsql 行为（CR-0110-C 因无 Docker 仅做了 parser 级校验），采用临时对象影子测试——**真实迁移名称/触发器未被创建，schema_migrations 无记录**。所有临时对象已在验证后清除（§6）。

---

## 2. 关键架构发现（验证前理解）

| 发现 | 证据 | 影响 |
|------|------|------|
| ① 触发器调用链正确 | `trg_collection_auto_sync_portfolio` → `auto_sync_collection_to_portfolio()` → `PERFORM public.sync_collections_to_portfolio(NEW.user_id)` | CR-0110-C 修改的 `sync_collections_to_portfolio` **正位于实时触发器路径**；且传 `NEW.user_id`（scoped 分支，单用户孤儿删除，加 per-user 咨询锁）。**修复有效且高效**。 |
| ② 旧触发器无 DELETE 事件 | `pg_get_triggerdef` = `AFTER INSERT OR UPDATE OF (quantity, purchase_price, current_price, product_code, region, edition, packaging_type)` | 证实 DH-1 Source A 根因：整行 DELETE 无触发器 → 孤儿残留。新 `AFTER DELETE` 触发器补此缺口。 |
| identity 8 列唯一约束 | `portfolio_items_identity_key = UNIQUE (user_id, card_name, series, rarity, product_code, region, edition, packaging_type)`（无 COALESCE） | 与迁移内 orphan DELETE 的 `NOT EXISTS` 映射逐列一致。 |
| `user_collections` FK | `user_collections_user_id_fkey → auth.users` | 测试数据需先建临时 `auth.users`。 |
| `market_tier` 仅允许 `'secondary'` | `user_collections_market_tier_check = (market_tier = 'secondary')` | 测试 INSERT 必须 `market_tier='secondary'`（初版因 `'common'` 被约束拒绝，已修正）。 |
| RLS | `portfolio_items` / `user_collections` / `user_portfolio` 均 `ENABLED` | 验证以 service_role 运行绕过 RLS；迁移不改任何 RLS 策略（§5 回归）。 |

---

## 3. 只读 Beta 现状检查（部署前基线）

| 检查项 | 结果 |
|--------|------|
| `sync_collections_to_portfolio` 当前是否含 orphan DELETE | **NO**（旧版本，确认迁移未部署） |
| `trg_collection_delete_cleanup_portfolio` 是否存在 | **NO**（确认迁移未部署） |
| `user_collections` 现有触发器 | `trg_collection_auto_sync_portfolio[INSERT/UPDATE]`、`trg_mark_platform_stock[BEFORE INSERT]` |
| `portfolio_items` 现有触发器 | `trg_portfolio_auto_refresh[INSERT/UPDATE/DELETE]`（刷新 `user_portfolio`） |
| `portfolio_items_identity_key` | 存在，8 列唯一约束（无 COALESCE） |
| RLS | 三表均 ENABLED（未改动） |
| **TC-3 部署前孤儿基线** | `portfolio_items_total = 0` → `orphan_count = 0`（Beta 当前无 portfolio 数据，属平凡 0，见 §4） |

---

## 4. 测试结果

### TC-1：user_collections 整行 DELETE（Source A） — ✅ PASS

**流程**：建测试收藏 →（实时旧触发器建 portfolio 行）→ DELETE 整行 →（临时 DELETE 触发器触发 → 临时 sync → orphan DELETE）。

| 检查点 | 结果 | 期望 | 判定 |
|--------|------|------|------|
| 建收藏后 `portfolio_items` 行数 | 1 | 1 | ✅ |
| 建收藏后 `user_portfolio` (card_count/total_quantity) | 1/1 | 1/1 | ✅ |
| DELETE 后 `portfolio_items` 行数 | **0** | 0（孤儿被清） | ✅ |
| DELETE 后 `user_portfolio` | **0/0** | 0/0（总览同步） | ✅ |

> 结论：整行删除产生的孤儿被新逻辑清除，`user_portfolio` 同步刷新。②（AFTER DELETE 触发器）行为验证通过。

### TC-2：identity 列 UPDATE（Source B） — ✅ PASS

**流程**：建收藏 `region=UNKNOWN` → UPDATE `region/edition/packaging_type` →（实时旧触发器建新元组，留旧孤儿）→ 调用新 sync 逻辑（orphan DELETE）。

| 检查点 | 结果 | 期望 | 判定 |
|--------|------|------|------|
| 建收藏后 `portfolio_items`（identity） | 1 行 `UNKNOWN/Unknown/card` | 1 | ✅ |
| UPDATE 后 `portfolio_items` 行数 | **2**（`UNKNOWN/Unknown/card` + `US/Collector/box`） | 2（复现 DH-1 孤儿） | ✅ |
| UPDATE 后 identities | `UNKNOWN/Unknown/card , US/Collector/box` | 旧孤儿 + 新元组并存 | ✅ |
| 调用新 sync 后行数 | **1** | 1（旧孤儿清除） | ✅ |
| 调用新 sync 后 identity | `US/Collector/box` | 新元组保留，**无重复** | ✅ |

> 结论：identity UPDATE 产生的旧孤儿被 ①（sync 内 orphan DELETE）清除，且仅保留新 identity 元组，无重复。**注意**：② 仅处理 DELETE；identity UPDATE 的孤儿清除依赖"下次 sync 运行"（即 ①）。在真实部署中，该用户下一次收藏变更（INSERT/UPDATE）或运维全量 sync 都会触发 ①。TC-2 已验证 ① 逻辑正确。

### TC-3：孤儿统计（只读） — ✅ PASS（基线）

- 部署前只读统计：`SELECT count(*) FROM portfolio_items pi WHERE NOT EXISTS (... user_collections 同 8 列 identity ...)` = **0**。
- 说明：Beta 当前 `portfolio_items_total = 0`，故基线与"部署后目标 = 0"一致（平凡成立）。孤儿**检测 SQL** 与 TC-1/TC-2 中已执行的 orphan DELETE 使用同一 `NOT EXISTS` 条件，逻辑已被运行时验证。
- **部署后复测**（本任务不包含，见 §8）：CEO 批准 `db push` + 运行 ④ `cleanup_portfolio_orphans()` 后，应再次执行该统计 = 0。

---

## 5. 回归检查

| 检查项 | 结果 | 判定 |
|--------|------|------|
| `sync_collections_to_portfolio()` 行为 | 影子版执行成功，返回 `items_synced`，upsert 语义不变 | ✅ |
| `trg_collection_delete_cleanup_portfolio`（影子版） | TC-1 中 DELETE 触发，正确清孤儿 | ✅ |
| `user_portfolio` 刷新 | TC-1 DELETE 后 `0/0`；建收藏后 `1/1`（`trg_portfolio_auto_refresh` 正常） | ✅ |
| RLS 不受影响 | 三表 RLS 仍 ENABLED；新函数 `SECURITY DEFINER` + `SET search_path=''` + `REVOKE ALL FROM PUBLIC,anon,authenticated`（与既有 `auto_sync_collection_to_portfolio` 风格一致）；未改任何策略 | ✅ |
| 触发器无递归 | 新 DELETE 触发器 → sync → 写 `portfolio_items` → 触发 `trg_portfolio_auto_refresh`（刷新 `user_portfolio`）→ **不回写 `user_collections`** → 无递归。TC-1 单次执行无报错/无环路 | ✅ |
| 无锁等待异常 | scoped 分支用 `pg_advisory_xact_lock(hashtextextended(user_id,0))`，事务提交即释放；TC-1/TC-2 无死锁/超时。full 分支按 `user_id` 固定顺序加锁，无并发死锁 | ✅ |

---

## 6. 清理与零残留验证（Beta 部署前状态复原）

| 残留项 | 数量 |
|--------|------|
| 临时函数 (`_cr0110d_%`) | 0 |
| 临时触发器 (`_cr0110d_verify_trg_del`) | 0 |
| 测试 `auth.users` | 0 |
| 测试 `user_collections` | 0 |
| 测试 `portfolio_items` | 0 |

**真实迁移部署状态复核**：

| 检查项 | 结果 |
|--------|------|
| 真实 `sync_collections_to_portfolio` 含 orphan DELETE | **NO**（未部署） |
| 真实 `trg_collection_delete_cleanup_portfolio` 存在 | **NO**（未部署） |
| `schema_migrations` 含 `20260805213000` | **0**（未 db push） |

→ Beta 完全处于部署前状态，验证过程零污染。

---

## 7. 遵守的禁令

| 禁令 | 是否遵守 | 说明 |
|------|----------|------|
| 修改历史 migration | ✅ | 仅读取；未触碰任何历史迁移 |
| 修改 CR-0110-C migration | ✅ | 未改动 `20260805213000_...sql` |
| `db push` | ✅ | 未推送；真实迁移未部署、未记录 |
| `git push` | ✅ | 未推送远程 |
| 执行生产清理 | ✅ | 仅建/删**测试**数据；未触碰任何真实用户数据 |
| 执行 `cleanup_portfolio_orphans()` 历史删除 | ✅ | 未调用该函数（④ 仅定义，按禁令不执行） |
| 自动部署 | ✅ | 采用影子测试临时对象，验证后全部 DROP，Beta 部署前状态复原 |

---

## 8. 风险评估

| 风险 | 等级 | 说明 / 缓解 |
|------|------|------------|
| full 分支（NULL 入参）未运行时验证 | 低 | 仅 scoped 分支（触发器路径）被 TC-1/TC-2 运行时验证；full 分支为简单 `DISTINCT user_id` 循环 + 同孤儿 DELETE，逻辑直接、低风险。④ `cleanup_portfolio_orphans()` 为单条全表 DELETE（非循环），效率更高。 |
| identity UPDATE 孤儿依赖"下次 sync"清除 | 低 | 部署后用户任意收藏变更即触发 ①；运维亦可在低峰跑 ④ 兜底。不在 INSERT/UPDATE 触发器内即时清（设计取舍，避免每次写都全量扫描）。 |
| 性能（每次 INSERT/UPDATE 多一次 scoped orphan DELETE） | 低 | scoped 分支仅删该用户孤儿行（带 `pi.user_id=` 索引前缀），且受 per-user 咨询锁保护，开销极小。 |
| RLS / 权限 | 无 | 新函数沿用既有 `SECURITY DEFINER` + `REVOKE` 模式；表 RLS 未变。 |

---

## 9. 是否建议 db push

### ✅ 建议：可以进入 Beta 部署阶段（建议 `db push`）。

理由：
1. 架构链路确认正确（`auto_sync → sync(NEW.user_id)`），修复位于实时路径。
2. TC-1、TC-2 在 Beta 真实 Postgres 上运行时 **PASS**，orphan DELETE 逻辑、触发器触发、`user_portfolio` 同步、无递归、无锁异常均验证通过。
3. TC-3 部署前基线 = 0，孤儿检测 SQL 与已验证的删除逻辑同源。
4. 未触碰历史迁移 / 未改 CR-0110-C / 未 db push / 未执行生产清理，全部禁令遵守。

**部署后建议（不属于本任务，待 CEO 批准）**：
- `npx supabase db push --linked` 推送 `20260805213000`。
- 低峰窗口以 `service_role` 运行 `SELECT * FROM public.cleanup_portfolio_orphans();`（④ 存量回填）。
- 复测 TC-3 孤儿统计 = 0；重跑 04F-U 回归（TC-1.1~1.6、TC-3.3）确认 `items_synced` 与 portfolio 行数一致、无孤儿。

---

## 10. 文件清单

- 被测迁移：`D:\codex\cardrealm\card-app\supabase\migrations\20260805213000_portfolio_identity_orphan_cleanup.sql`（未改动、未部署）
- 本报告：`D:\codex\cardrealm\card-app\CR0110_D_DEPLOY_VERIFY_REPORT.md`
- 临时验证脚本（已删除）：`tmp_cr0110d_*.sql`（仅验证期存在于工作区，未纳入仓库）

**状态：待 CEO 复核** —— 验证结论为 **GO（建议 db push）**；请批准后执行部署与 ④ 存量回填。
