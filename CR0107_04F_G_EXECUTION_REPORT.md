# CR-0107-04F-G_PATH_B_RENAME — EXECUTION REPORT

**项目**: `D:\codex\cardrealm\card-app`
**执行时间**: 2026-08-05
**任务**: 执行 CR0107_04F_G_PATH_B_RENAME_PLAN — 将 `00XX_*.sql` 序号格式 migration 重命名为 `202401010000XX_*.sql` timestamp 格式
**约束遵守**: ❌ 未执行 `migration repair` / `db push` / `commit` / `push`；未删除任何文件、未修改任何 SQL 内容

---

## 1. 执行摘要

| 项目 | 结果 |
|---|---|
| 重命名总数 | **58** 个 `00XX_*` → `202401010000XX_*` |
| Batch A (0001–0033) | 33 个，全部 `git mv`（已 tracked） |
| Batch B (0035–0061) | 25 个 = 11 个 `git mv`（tracked: 0035–0044, 0048）+ 14 个 `mv`（untracked: 0045, 0049–0061） |
| 跳过 | `0034`（已有 authoritative）、`0046`、`0047`（无源） |
| 旧 `00XX_*.sql` 残留 | **0**（顶层无 `00XX_*`） |
| `20240101000034_*` authoritative | 保留存在 ✅ |
| 内容完整性（sha256） | 全部 **字节级一致**（58/58） |
| 引入的 `M`（修改） | **0**（重命名未改动内容） |

---

## 2. 验证结果（对照任务 4 项要求）

### CHK1 — `git status --porcelain`
本任务产生的变更类型（已与本任务前既有工作区状态剥离）：
- `R `（tracked rename）：**44** 条（33 Batch A + 11 Batch B tracked）
- `??`（untracked，plain-mv 新位置）：**14** 条（Batch B untracked）+ **1** 条（authoritative，自 04F-D 起即未提交）
- 对任一 `202401010000XX_*` 文件的 `M`（修改）：**0** ✅

> 注：仓库当前整体 `git status` 仍有 `D`/`M`/`??` 条目，均来自**本任务之前**各 CR 任务遗留的工作区状态，与本次重命名无关。本次重命名**仅**产生 `R` 与 `??`，未对任何文件内容做修改。

### CHK2 — `supabase/migrations/` 不存在 `0001_*.sql` 等
```
ls 00[0-9][0-9]_*.sql → No such file or directory
count = 0  ✅
```

### CHK3 — `20240101000034_tiered_market_system_authoritative.sql` 存在
```
✅ 存在（在 migrations/ 顶层，供 CLI 识别）
```

### CHK4 — 完整性
- `202401010000XXXX_*.sql`（4 位后缀）共 **58** 个 + authoritative（2 位后缀 `34`）= 目录内 **59** 个 ts 文件
- Batch A 33 文件 + Batch B 25 文件，**全部 sha256 前后一致**：
  - `BATCH_A_HASHES_IDENTICAL_OK`
  - `BATCH_B_HASHES_IDENTICAL_OK`

---

## 3. 关键实现细节：git mv vs 普通 mv

Batch B 中 **14 个文件（0045, 0049–0061）从未被 commit**（属于后续 CR 任务新建、尚未纳入版本控制的迁移），`git mv` 对其报 `fatal: not under version control` 并中止循环。处理方式：

- **tracked 文件（44 个）**：`git mv` — 保留 rename 历史，`git status` 显示 `R`，可被 `git diff -M` 识别为改名。
- **untracked 文件（14 个）**：`mv`（普通移动）— 因为文件不在索引中，`git mv` 无法应用；移动后 git 视其为新位置上的未跟踪文件（`??`）。内容字节不变（sha256 已验证）。

> 这与 04E_PREP_PLAN 中 Method B（普通 mv + git rm --cached + git add）的惯例一致，且对这些**从未提交**的文件，无需 `git rm --cached`。

---

## 4. 完整重命名清单（58 条）

### 4.1 Batch A — `git mv`（33，tracked）
```
0001_add_market_listings_columns.sql            → 2024010100000001_add_market_listings_columns.sql
0002_add_feedback_table.sql                     → 2024010100000002_add_feedback_table.sql
0003_add_dashboard_tables.sql                   → 2024010100000003_add_dashboard_tables.sql
0004_add_collection_tables.sql                  → 2024010100000004_add_collection_tables.sql
0005_add_community_tables.sql                   → 2024010100000005_add_community_tables.sql
0006_add_marketplace_tables.sql                 → 2024010100000006_add_marketplace_tables.sql
0007_add_points_system.sql                      → 2024010100000007_add_points_system.sql
0008_add_missing_features.sql                   → 2024010100000008_add_missing_features.sql
0009_add_recharge_status.sql                     → 2024010100000009_add_recharge_status.sql
0010_add_ai_scan_logs.sql                       → 2024010100000010_add_ai_scan_logs.sql
0011_market_pricing_system.sql                  → 2024010100000011_market_pricing_system.sql
0012_trading_inventory_system.sql               → 2024010100000012_trading_inventory_system.sql
0013_risk_control_system.sql                    → 2024010100000013_risk_control_system.sql
0014_shop_system.sql                            → 2024010100000014_shop_system.sql
0015_growth_retention.sql                       → 2024010100000015_growth_retention.sql
0016_reservation_system.sql                     → 2024010100000016_reservation_system.sql
0017_ai_scan_fault_tolerance.sql                → 2024010100000017_ai_scan_fault_tolerance.sql
0018_order_status_machine.sql                   → 2024010100000018_order_status_machine.sql
0019_add_user_management_fields.sql             → 2024010100000019_add_user_management_fields.sql
0020_fallback_card_entry.sql                    → 2024010100000020_fallback_card_entry.sql
0021_asset_marketization.sql                    → 2024010100000021_asset_marketization.sql
0022_price_history_market_trends.sql            → 2024010100000022_price_history_market_trends.sql
0023_lock_price_truth_rule.sql                  → 2024010100000023_lock_price_truth_rule.sql
0024_price_lock_mechanism.sql                   → 2024010100000024_price_lock_mechanism.sql
0025_dynamic_weight_pricing_engine.sql          → 2024010100000025_dynamic_weight_pricing_engine.sql
0026_portfolio_use_mark_price.sql              → 2024010100000026_portfolio_use_mark_price.sql
0027_price_explanation_system.sql              → 2024010100000027_price_explanation_system.sql
0028_fix_price_explanation_format.sql          → 2024010100000028_fix_price_explanation_format.sql
0029_market_data_seeding.sql                    → 2024010100000029_market_data_seeding.sql
0030_fix_compute_card_market_price.sql          → 2024010100000030_fix_compute_card_market_price.sql
0031_fix_market_state_trigger.sql              → 2024010100000031_fix_market_state_trigger.sql
0032_merchant_role_platform_stock_live_sync.sql→ 2024010100000032_merchant_role_platform_stock_live_sync.sql
0033_platform_issued_inventory_system.sql      → 2024010100000033_platform_issued_inventory_system.sql
```

### 4.2 Batch B — `git mv`（11，tracked）
```
0035_payment_escrow_system.sql                 → 2024010100000035_payment_escrow_system.sql
0036_production_rls_security_fixes.sql         → 2024010100000036_production_rls_security_fixes.sql
0037_image_upload_security.sql                 → 2024010100000037_image_upload_security.sql
0038_admin_auth_unification_phase1.sql         → 2024010100000038_admin_auth_unification_phase1.sql
0039_admin_orders_rpc.sql                      → 2024010100000039_admin_orders_rpc.sql
0040_admin_rpc_group_a.sql                     → 2024010100000040_admin_rpc_group_a.sql
0041_admin_rpc_group_b.sql                     → 2024010100000041_admin_rpc_group_b.sql
0042_admin_rpc_group_c.sql                     → 2024010100000042_admin_rpc_group_c.sql
0043_admin_rpc_group_d_disable.sql            → 2024010100000043_admin_rpc_group_d_disable.sql
0044_financial_fk_safety.sql                   → 2024010100000044_financial_fk_safety.sql
0048_profiles_rls_security_fix.sql            → 2024010100000048_profiles_rls_security_fix.sql
```

### 4.3 Batch B — `mv`（14，untracked，原未 commit）
```
0045_marketplace_transaction_gate.sql         → 2024010100000045_marketplace_transaction_gate.sql
0049_auth_profile_sync.sql                     → 2024010100000049_auth_profile_sync.sql
0050_profile_backfill.sql                      → 2024010100000050_profile_backfill.sql
0051_portfolio_auto_sync.sql                   → 2024010100000051_portfolio_auto_sync.sql
0052_portfolio_sync_idempotency.sql           → 2024010100000052_portfolio_sync_idempotency.sql
0053_portfolio_model_alignment.sql            → 2024010100000053_portfolio_model_alignment.sql
0054_marketplace_order_rpc_restore.sql        → 2024010100000054_marketplace_order_rpc_restore.sql
0055_pay_with_balance_hardening.sql           → 2024010100000055_pay_with_balance_hardening.sql
0056_fulfillment_escrow_hardening.sql         → 2024010100000056_fulfillment_escrow_hardening.sql
0057_cancel_order_rpc.sql                      → 2024010100000057_cancel_order_rpc.sql
0058_cancel_order_rpc_fix.sql                  → 2024010100000058_cancel_order_rpc_fix.sql
0059_payment_callbacks.sql                     → 2024010100000059_payment_callbacks.sql
0060_payment_callback_verification.sql        → 2024010100000060_payment_callback_verification.sql
0061_payment_success_internal.sql             → 2024010100000061_payment_success_internal.sql
```

---

## 5. 跳过的 version

| version | 原因 |
|---|---|
| `0034` | 已有 `20240101000034_tiered_market_system_authoritative.sql`（04F-D 生成，结构真相源） |
| `0046` | 无源文件（历史缺失，详见 04F-A/B/C） |
| `0047` | 无源文件（历史缺失） |

---

## 6. 后续衔接步骤（均需另行授权，本次未执行）

1. **`git add` + `commit`**：纳入 44 个 `R` 改名 + 14 个 `??` 新位置 + authoritative + 04F-E 归档（4 个 `R`）。
2. **`supabase migration repair --status applied`**：对全部 **59 个**本地 ts version（`20240101000001`–`61` 中除 46/47，加上 9 个真实 `202608*`）写 `schema_migrations` 历史。
   - ⚠️ **必须先于任何 `db push`** 执行，否则 CLI 会把这 59 个文件当成"待应用"重放（虽文件幂等，但会产生噪声且可能触发约束错误）。
3. **`supabase migration list`** 验收：Local 与 Remote 列对齐。
4. （可选）**`db reset` 后比对**：`pg_dump --schema-only` 结构 + 7 RPC `pg_get_functiondef` 逐字节一致。

---

## 7. 约束遵守确认

| 禁止项 | 是否触碰 |
|---|---|
| `migration repair` | ❌ 未执行 |
| `db push` | ❌ 未执行 |
| `commit` | ❌ 未执行 |
| `push` | ❌ 未执行 |
| 删除文件 | ❌ 未删除（仅改名/移动） |
| 修改 SQL 内容 | ❌ 未修改（sha256 全部一致） |

---

**状态**: ⏳ WAITING CEO REVIEW
