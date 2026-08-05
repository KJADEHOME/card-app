# CR-0110-E · Beta Migration Deploy Report

**任务**: 部署经 CR-0110-D 验证的 migration `20260805213000_portfolio_identity_orphan_cleanup.sql`
**目标**: 修复 DH-1（portfolio identity orphan 不清理）
**环境**: CardRealm Beta — Supabase ref `xybpcsmjjcnkjwfsuder`（经 2026-07-29 人工确认为 Beta 环境）
**执行时间**: 2026-08-05 22:17–22:19 (GMT+8)
**执行人**: WorkBuddy (Craft)
**状态**: ✅ 部署成功，验证全过 — **WAITING CEO REVIEW**

---

## 1. 执行前检查（Pre-deploy Checks）

| 检查项 | 结果 |
|--------|------|
| 当前分支 | `release-beta-preparation` ✅ |
| `db push` 待部署清单 | 仅 `20260805213000` 1 个（Local 有 / Remote 空），其余 68 个均已 Remote 应用 ✅ |
| migration 文件存在 | `supabase/migrations/20260805213000_portfolio_identity_orphan_cleanup.sql`（10934 bytes），git 中为 untracked 新文件，**无未授权修改** ✅ |
| git status 旁证 | 工作区存在其他历史 modified/deleted/untracked 文件，但与本任务目标 migration 无关，未触碰 ✅ |

> 说明：`npx supabase migration list --linked` 确认 Remote 最新应用到 `20260805170000`（CR-0110-C 的 SF-1 owner-check，已先前部署），故本次 `db push` 仅推送 `20260805213000` 单个迁移，无额外/意外迁移。

---

## 2. SQL 执行结果（Deploy）

```text
$ npx supabase db push --linked
Initialising login role...
Connecting to remote database...
Do you want to push these migrations to the remote database?
 • 20260805213000_portfolio_identity_orphan_cleanup.sql
 [Y/n] Applying migration 20260805213000_portfolio_identity_orphan_cleanup.sql...
Finished supabase db push.
```

- 推送迁移数：**1**（`20260805213000`）
- 报错：**无**
- 退出状态：成功

---

## 3. 部署后验证（Post-deploy Verification）

### 3.1 Migration 记录
```text
version        | name
---------------+----------------------------------
20260805213000 | portfolio_identity_orphan_cleanup
```
✅ 已进入 `supabase_migrations.schema_migrations`

### 3.2 函数存在性
```text
 sync_exists | cleanup_on_delete_exists | cleanup_orphans_exists | sync_has_orphan_delete
-------------+--------------------------+-----------------------+------------------------
 1           | 1                        | 1                     | 1
```
- `sync_collections_to_portfolio()` ✅
- `cleanup_portfolio_on_collection_delete()` ✅
- `cleanup_portfolio_orphans()` ✅（④ 存量回填函数，仅定义，未执行）
- 部署后的 `sync_collections_to_portfolio` 函数体含 orphan DELETE 逻辑（`NOT EXISTS`）✅

### 3.3 Trigger 状态
```text
tgname                                    | def
------------------------------------------+-------------------------------------------------------------------------------------------------------------------------
trg_collection_delete_cleanup_portfolio   | CREATE TRIGGER trg_collection_delete_cleanup_portfolio
                                           |   AFTER DELETE ON public.user_collections
                                           |   FOR EACH ROW EXECUTE FUNCTION cleanup_portfolio_on_collection_delete()
```
✅ 触发器 `trg_collection_delete_cleanup_portfolio` 已挂载于 `user_collections` 的 `AFTER DELETE`。

### 3.4 Orphan 统计（只读）
```text
 portfolio_items_total | orphan_count
-----------------------+--------------
 0                     | 0
```
✅ Beta 当前无 portfolio 数据，`orphan_count = 0`。检测 SQL 与 CR-0110-C migration 中 orphan DELETE 的 `NOT EXISTS` 映射一致（8 列 identity + COALESCE）。

---

## 4. 回归确认（来自 CR-0110-D 已验证结论 + 本次部署确认）

| 项 | 状态 |
|----|------|
| 触发器链路径正确：`trg_collection_auto_sync_portfolio → auto_sync_collection_to_portfolio() → sync_collections_to_portfolio(NEW.user_id)`（scoped 分支，orphan DELETE 随每次收藏变更运行） | ✅ |
| `trg_collection_delete_cleanup_portfolio`（新增 AFTER DELETE）与既有 `trg_collection_auto_sync_portfolio`（AFTER INSERT/UPDATE）事件不重叠，无递归 | ✅ |
| `cleanup_portfolio_on_collection_delete` 内部重跑 `sync()`，orphan 由 ① 的 DELETE 精确清除；不按 OLD 直接删，避免误伤同 identity 多行 | ✅ |
| RLS 未改动（本次 migration 不改表/策略）；`portfolio_items`/`user_collections`/`user_portfolio` RLS 仍启用 | ✅ |
| 写入加 `pg_advisory_xact_lock`，按 user_id 顺序锁定，排除并发死锁/长锁 | ✅ |
| `user_portfolio` 总览由既有 `trg_portfolio_auto_refresh` 随 portfolio_items 增删自动刷新 | ✅ |

> 行为级验证（TC-1 删整行收藏 / TC-2 identity UPDATE）已在 CR-0110-D 用同源逻辑的影子对象于真实 Beta Postgres 完整跑通（PASS），本次部署未重复执行以遵守「不生产清理 / 不留测试足迹」原则；如需上线后回归，建议低峰跑一次轻量 smoke test（见 §6）。

---

## 5. 风险说明（Risk Notes）

| 风险 | 等级 | 说明 / 缓解 |
|------|------|------------|
| 存量孤儿未清理 | 低 | Beta 当前 `orphan_count=0`（无数据），但生产/其他环境若已有孤儿，需执行 ④ 才能清零（见 §6） |
| 触发路径性能 | 低 | scoped 分支按 `user_id` 仅扫该用户 portfolio，已有 advisory 锁保护；全量分支（NULL）仅 ④ 调用 |
| 同 identity 多行误删 | 低 | ② 设计为「重跑 sync + ① 精确 DELETE」，已规避直接按 OLD 删的误伤 |
| 部署后未做实时触发冒烟 | 低 | 逻辑已在 D 验证；若 CEO 要求，可于低峰补一次轻量 TC-1/TC-2（会留瞬时测试数据，需清理） |
| 迁移文件未 git commit | 中 | 本任务遵守「禁止 git push」；文件仍 untracked，需另排 commit（连同 CR-0110-A/C 报告）入版本库 |

---

## 6. 是否建议执行 ④ cleanup（cleanup_portfolio_orphans）

**结论：Beta 当前不建议执行（无必要）；但建议在「低峰 + 有存量孤儿的环境」执行。**

- Beta 现状 `orphan_count = 0` → 执行 ④ 不删除任何行，纯无操作，**无收益也无风险**。
- 若后续发现某环境（如生产或其他 Beta 克隆）存在存量孤儿（`orphan_count > 0`），建议在低峰以 `service_role` 执行：
  ```sql
  SELECT cleanup_portfolio_orphans();   -- ④ 一次性存量回填清理
  -- 执行后复测：
  SELECT COUNT(*) FROM public.portfolio_items pi
  WHERE NOT EXISTS ( /* 8 列 identity + COALESCE 同 §3.4 */ );
  -- 期望 = 0
  ```
- 执行 ④ 会按 `DISTINCT user_id` 顺序加 advisory 锁重跑 sync，单次删除该用户孤儿，避免全表长锁与并发死锁。

> 本任务严格遵守禁令：**未执行 `cleanup_portfolio_orphans()`**（函数已部署但保持未运行）。

---

## 7. 遵守的禁令（Prohibitions Honored）

- ❌ 未 `git push`（迁移文件仍为 untracked，待另排 commit）
- ❌ 未执行 `cleanup_portfolio_orphans()`（④ 仅定义/部署，未调用）
- ❌ 未做生产部署（仅 Beta 环境）
- ❌ 未修改历史 migration（本次仅新增 1 个迁移，其余 68 个零改动）
- ❌ 未留测试足迹（验证均为只读探针 + 清理临时 SQL）

---

## 8. 交付物

- 部署对象：`supabase/migrations/20260805213000_portfolio_identity_orphan_cleanup.sql` → 已上 Beta
- 本报告：`CR0110_E_BETA_DEPLOY_REPORT.md`

**状态：待 CEO 复核** — 部署成功、验证全过。建议下一步：
1. 复核后安排 `git commit` 该迁移文件（及 CR-0110-A/C/D 报告）纳入版本库；
2. 视需要决定是否在低峰执行 ④ 存量回填（Beta 当前无必要）。
