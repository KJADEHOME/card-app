# CR0107-04F-G · Path B Migration Version 重命名计划（PREP ONLY）

> **任务性质**：仅制定重命名计划，**不执行**。
> **状态**：⏳ WAITING CEO REVIEW
> **项目**：`D:\codex\cardrealm\card-app`
> **生成时间**：2026-08-05

---

## 1. 目标（Objective）

将 `supabase/migrations/` 中剩余的 **58 个非 timestamp 格式**（`00XX_*.sql`）migration，
按 Path B 约定重命名为 **synthetic timestamp 格式** `202401010000XX_*.sql`，使 Supabase CLI
能识别并纳入 tracking（`supabase migration list` 的 Local 列从空变为 68 条）。

保留已为 timestamp 格式的 10 个文件（含 `20240101000034` 权威 0034）**不动**。

---

## 2. 当前已验证清单（Verified Inventory）

| 类别 | 数量 | 说明 |
|---|---|---|
| 非 timestamp（`00XX_*.sql`） | **58** | 本次重命名对象 |
| timestamp（`YYYYMMDDHHMMSS_*.sql`） | **10** | 已合规，不重命名 |
| `_archive/` 目录 | 1 | 归档的 4 份旧 0034（不在扫描范围） |
| **合计 .sql 文件** | **68** | 58 + 10 |

### 10 个已合规 timestamp 文件（不动）

```
20240101000034_tiered_market_system_authoritative.sql   ← 权威 0034（04F-D 生成）
20260801122630_transaction_write_surface_lockdown.sql   ← 原 drift，04E 已改名
20260801124633_product_catalog_write_surface_lockdown.sql
20260801142033_payment_refund_authorization_hardening.sql ← 04D-C 恢复
20260802035915_enforce_payment_callback_failed_reason.sql
20260802040518_secondary_market_security_invoker.sql
20260802074652_consignments_read_surface_lockdown.sql
20260802100000_recognition_product_identity.sql
20260802113000_card_collection_quantity_upsert.sql
20260804230000_rls_owner_scoped_restore_batch1.sql        ← 03A-1 RLS 修复
```

---

## 3. 检查结论（Duplicate / Gap / Conflict）

| 检查项 | 结果 |
|---|---|
| **重复 version**（多个 `00XX` 同名前缀） | ✅ **无**（58 文件版本号 1–61 全唯一） |
| **缺失 version** | `34`（已由权威文件 `20240101000034` 覆盖，不重命名）、`46`、`47`（无源文件，跳过） |
| **目标命名冲突**（58 个 `202401010000XX` 互撞） | ✅ **无**（Counter 校验通过） |
| **与现有 10 个 timestamp 文件冲突** | ✅ **无**（synthetic 前缀 `20240101` ≠ 现有 `202608`；`20240101000034` 已存在但 0034 不在本次重命名列表） |
| **`_archive/` 内 4 份旧 0034** | 不重命名（已出扫描范围） |

> 结论：**58 个重命名全部安全，无碰撞、无歧义**。

---

## 4. 重命名规则（Rule）

```
原：  <XX><_name>.sql          例: 0035_payment_escrow_system.sql
新：  202401010000<XX><_name>.sql  例: 20240101000035_payment_escrow_system.sql
                              ^^^^^^^^^^^^ 12 位 synthetic timestamp = 2024-01-01 00:00:XX
```

- `202401010000` 为固定前缀（2024-01-01 00:00，**早于所有真实 timestamp 迁移 202608...**，
  保证 CLI 应用顺序正确：先跑完全部历史 00XX，再跑真实 2026 迁移）。
- 后缀 `_<name>.sql` 原样保留。
- 版本 `34` 跳过（已存在权威文件）；`46`/`47` 跳过（无源）。

---

## 5. 完整重命名映射（Full Mapping · 58 条）

```
0001_add_market_listings_columns.sql          -> 20240101000001_add_market_listings_columns.sql
0002_add_feedback_table.sql                    -> 20240101000002_add_feedback_table.sql
0003_add_dashboard_tables.sql                 -> 20240101000003_add_dashboard_tables.sql
0004_add_collection_tables.sql                -> 20240101000004_add_collection_tables.sql
0005_add_community_tables.sql                 -> 20240101000005_add_community_tables.sql
0006_add_marketplace_tables.sql               -> 20240101000006_add_marketplace_tables.sql
0007_add_points_system.sql                    -> 20240101000007_add_points_system.sql
0008_add_missing_features.sql                 -> 20240101000008_add_missing_features.sql
0009_add_recharge_status.sql                   -> 20240101000009_add_recharge_status.sql
0010_add_ai_scan_logs.sql                      -> 20240101000010_add_ai_scan_logs.sql
0011_market_pricing_system.sql                -> 20240101000011_market_pricing_system.sql
0012_trading_inventory_system.sql             -> 20240101000012_trading_inventory_system.sql
0013_risk_control_system.sql                   -> 20240101000013_risk_control_system.sql
0014_shop_system.sql                           -> 20240101000014_shop_system.sql
0015_growth_retention.sql                      -> 20240101000015_growth_retention.sql
0016_reservation_system.sql                    -> 20240101000016_reservation_system.sql
0017_ai_scan_fault_tolerance.sql               -> 20240101000017_ai_scan_fault_tolerance.sql
0018_order_status_machine.sql                  -> 20240101000018_order_status_machine.sql
0019_add_user_management_fields.sql            -> 20240101000019_add_user_management_fields.sql
0020_fallback_card_entry.sql                   -> 20240101000020_fallback_card_entry.sql
0021_asset_marketization.sql                   -> 20240101000021_asset_marketization.sql
0022_price_history_market_trends.sql          -> 20240101000022_price_history_market_trends.sql
0023_lock_price_truth_rule.sql                -> 20240101000023_lock_price_truth_rule.sql
0024_price_lock_mechanism.sql                 -> 20240101000024_price_lock_mechanism.sql
0025_dynamic_weight_pricing_engine.sql        -> 20240101000025_dynamic_weight_pricing_engine.sql
0026_portfolio_use_mark_price.sql             -> 20240101000026_portfolio_use_mark_price.sql
0027_price_explanation_system.sql             -> 20240101000027_price_explanation_system.sql
0028_fix_price_explanation_format.sql          -> 20240101000028_fix_price_explanation_format.sql
0029_market_data_seeding.sql                   -> 20240101000029_market_data_seeding.sql
0030_fix_compute_card_market_price.sql        -> 20240101000030_fix_compute_card_market_price.sql
0031_fix_market_state_trigger.sql             -> 20240101000031_fix_market_state_trigger.sql
0032_merchant_role_platform_stock_live_sync.sql -> 20240101000032_merchant_role_platform_stock_live_sync.sql
0033_platform_issued_inventory_system.sql     -> 20240101000033_platform_issued_inventory_system.sql
0035_payment_escrow_system.sql                -> 20240101000035_payment_escrow_system.sql
0036_production_rls_security_fixes.sql        -> 20240101000036_production_rls_security_fixes.sql
0037_image_upload_security.sql               -> 20240101000037_image_upload_security.sql
0038_admin_auth_unification_phase1.sql        -> 20240101000038_admin_auth_unification_phase1.sql
0039_admin_orders_rpc.sql                     -> 20240101000039_admin_orders_rpc.sql
0040_admin_rpc_group_a.sql                    -> 20240101000040_admin_rpc_group_a.sql
0041_admin_rpc_group_b.sql                    -> 20240101000041_admin_rpc_group_b.sql
0042_admin_rpc_group_c.sql                    -> 20240101000042_admin_rpc_group_c.sql
0043_admin_rpc_group_d_disable.sql            -> 20240101000043_admin_rpc_group_d_disable.sql
0044_financial_fk_safety.sql                  -> 20240101000044_financial_fk_safety.sql
0045_marketplace_transaction_gate.sql         -> 20240101000045_marketplace_transaction_gate.sql
0048_profiles_rls_security_fix.sql            -> 20240101000048_profiles_rls_security_fix.sql
0049_auth_profile_sync.sql                    -> 20240101000049_auth_profile_sync.sql
0050_profile_backfill.sql                     -> 20240101000050_profile_backfill.sql
0051_portfolio_auto_sync.sql                  -> 20240101000051_portfolio_auto_sync.sql
0052_portfolio_sync_idempotency.sql           -> 20240101000052_portfolio_sync_idempotency.sql
0053_portfolio_model_alignment.sql            -> 20240101000053_portfolio_model_alignment.sql
0054_marketplace_order_rpc_restore.sql        -> 20240101000054_marketplace_order_rpc_restore.sql
0055_pay_with_balance_hardening.sql           -> 20240101000055_pay_with_balance_hardening.sql
0056_fulfillment_escrow_hardening.sql         -> 20240101000056_fulfillment_escrow_hardening.sql
0057_cancel_order_rpc.sql                     -> 20240101000057_cancel_order_rpc.sql
0058_cancel_order_rpc_fix.sql                 -> 20240101000058_cancel_order_rpc_fix.sql
0059_payment_callbacks.sql                    -> 20240101000059_payment_callbacks.sql
0060_payment_callback_verification.sql        -> 20240101000060_payment_callback_verification.sql
0061_payment_success_internal.sql             -> 20240101000061_payment_success_internal.sql
```

---

## 6. 执行顺序（Execution Order · 供后续授权步骤使用，本任务不执行）

### 推荐方法：单目录 `git mv` 循环（保留历史 rename）

```bash
cd D:/codex/cardrealm/card-app/supabase/migrations
for f in 000[0-9]_*.sql 001[0-9]_*.sql 002[0-9]_*.sql 003[0-9]_*.sql \
         004[0-9]_*.sql 005[0-9]_*.sql 006[0-9]_*.sql; do
  [ -e "$f" ] || continue          # 跳过 0046/0047（不存在）及已归档的 0034（不在顶层）
  v="${f:0:4}"                      # 取前 4 位版本号
  rest="${f:4}"                     # 取剩余（含前导下划线 + 名称）
  git mv "$f" "202401010000${v}${rest}"
done
```

> 说明：
> - 58 个文件均 **TRACKED**，`git mv` 产生 `R ` rename，历史可追溯。
> - `0034` 因已归档不在顶层、`0046`/`0047` 不存在 → 循环自动跳过，无需特判。
> - 目标名均唯一且与现有 10 个 timestamp 文件无冲突（§3 已校验）。

### 执行后预期状态

```
supabase/migrations/
├── 20240101000001_*.sql ... 20240101000033_*.sql   (33 个, 原 0001-0033)
├── 20240101000034_tiered_market_system_authoritative.sql  (权威 0034, 已存在)
├── 20240101000035_*.sql ... 20240101000045_*.sql   (11 个, 原 0035-0045)
├── 20240101000048_*.sql ... 20240101000061_*.sql   (14 个, 原 0048-0061)
├── 20260801*.sql / 20260802*.sql / 20260804*.sql   (9 个真实 timestamp, 不动)
└── _archive/0034_redundant/                         (4 份旧 0034, 不动)
```

> 注意：版本 `46`/`47` 在 Local 列中将**永久缺失**（无源文件），这与线上实际状态一致（远程 `schema_migrations` 也无此二 version）。
> repair 步骤仅对**存在的 68 个 version**（59 synthetic + 9 real）执行。

---

## 7. 约束遵守（Constraints · 本任务）

| 禁止项 | 状态 |
|---|---|
| `git mv` | ❌ 未执行（仅出计划与脚本） |
| `migration repair` | ❌ 未执行 |
| `db push` | ❌ 未执行 |
| `commit` | ❌ 未执行 |
| `push` | ❌ 未执行 |
| 修改 SQL 内容 | ❌ 未修改（仅文件名变更） |

✅ 全部禁止项遵守。

---

## 8. 与 04F Path B 整体流程的衔接

本计划仅完成 Path B 的**文件名重命名**子步骤。完整 Path B 还需（均待后续授权）：

| 步骤 | 动作 | 状态 |
|---|---|---|
| 1 | 本计划：重命名 58 个 `00XX` → `202401010000XX` | ⏳ 待授权执行 |
| 2 | `git add` + `commit` 重命名变更 | 待授权 |
| 3 | `supabase migration repair --status applied <68 个 version>` | 待授权（需有效 PAT） |
| 4 | `supabase migration list` 验收 Local/Remote 对齐 | 待授权 |

> ⚠️ **`repair` 必须在任何 `db push` 之前**：未 repair 时 CLI 会把 68 个 migration 视为"待应用"并重放。
> 因文件为幂等（`IF NOT EXISTS` / `CREATE OR REPLACE`），重放不破坏数据，但会产生噪声与潜在告警。

---

## 9. 结论（Conclusion）

58 个非 timestamp migration 的重命名方案已完全确定：**无重复 version、无命名冲突、无缺失阻断（34/46/47 已合理排除）**。
映射规则与完整 58 条映射表已给出，执行脚本（单目录 `git mv` 循环）已就绪。
本任务仅出计划，未触碰任何文件或数据库。

状态：**⏳ WAITING CEO REVIEW**（建议批准步骤 1→2→3→4 衔接执行）。
