# SH-003C Phase 3 — FINAL IMPLEMENTATION PLAN V2

**日期**: 2026-07-13 (修订版)
**前置条件**: Phase 1 ✅ · Phase 2 ✅ · Git tag v0.9.5-admin-auth-phase2 (7aab7bb)
**目的**: 将旧平台管理员登录与发布流程迁移到统一 AdminAuth 体系，重写有前端调用者的旧管理 RPC，停用无调用者的僵尸 RPC
**⚠️ 本文档为计划，不实施。等待王总审核确认后才开始执行。**

---

## 一、迁移编号登记

最大已占用编号: **0039** (0039_admin_orders_rpc.sql, 已线上部署)
下一个可用编号: **0040**

Phase 3 占用编号:
| 编号 | 文件名 | Group | 状态 |
|------|--------|-------|------|
| 0040 | 0040_admin_rpc_group_a.sql | A (商品发布) | planned |
| 0041 | 0041_admin_rpc_group_b.sql | B (充值审批) | planned |
| 0042 | 0042_admin_rpc_group_c.sql | C (用户/商户) | planned |
| 0043 | 0043_admin_rpc_group_d_disable.sql | D (僵尸停用) | planned |

SH-006B 编号已因 0039 冲突调整为 0044-0046 (不影响 Phase 3)。

详细登记见: `supabase/migrations/MIGRATION_REGISTRY.md`

---

## 二、20 个旧 RPC 完整对账表

### 2.1 对账规则
- 排除已重写的 3 个 RPC (admin_cancel_order/process_refund/resolve_dispute — 0039 已用 require_admin())
- 排除辅助函数 (require_admin/is_platform_admin/log_admin_action — 0038 新建)
- 排除触发器函数 (trg_mark_platform_stock/sale/trg_update_platform_cards_timestamp)
- 排除公开查询 (get_platform_card_list — 无认证，保持原样)
- **计入 20 个旧 RPC**: 包含所有有认证问题需处理的函数

### 2.2 完整对账

| # | schema | function_name | 完整参数签名 | 来源migration | 认证模式 | 前端/脚本/Edge/DB调用者 | 当前权限 (authenticated/anon EXECUTE) | 新处理方案 | 归属Group |
|---|--------|---------------|-------------|--------------|----------|----------------------|-------------------------------------|-----------|----------|
| 1 | public | **admin_login** | `p_username text, p_password text, p_session_duration_hours integer DEFAULT 24` | 0033 | 0033-token (admins表用户名/密码→session_token) | admin-platform-login.html | ✅✅ (both granted) | **废弃**: Supabase Auth signInWithPassword 替代。A4阶段停用。 | A4 |
| 2 | public | **verify_admin_token** | `p_token text` | 0033 | 0033-token (查admins.session_token) | 无前端调用 (内部辅助) | ✅✅ | **废弃**: require_admin() 替代。A4阶段停用。 | A4 |
| 3 | public | **admin_logout** | `p_token text` | 0033 | 0033-token (删除admins.session_token) | admin-platform-publish.html | ✅✅ | **废弃**: db.auth.signOut() + AdminAuth.logout() 替代。A4阶段停用。 | A4 |
| 4 | public | **admin_publish_card** | `p_admin_token text, p_name text, p_set_name text DEFAULT '', p_card_image_url text DEFAULT NULL, p_images text[] DEFAULT '{}', p_thumbnail_url text DEFAULT NULL, p_description text DEFAULT '', p_card_category text DEFAULT 'pokemon', p_rarity text DEFAULT 'N', p_condition text DEFAULT 'NM', p_initial_cost_price numeric DEFAULT 0, p_listing_price numeric DEFAULT 0, p_stock_quantity integer DEFAULT 1, p_platform_fee_pct numeric DEFAULT 0, p_shipping_fee numeric DEFAULT 0` | 0033 | 0033-token (p_admin_token→admins.session_token) | admin-platform-publish.html | ✅✅ | **重写→v2**: 删除p_admin_token→require_admin()+audit+幂等。前端同步改。 | A3 |
| 5 | public | **admin_update_platform_card** | `p_admin_token text, p_platform_card_id uuid, p_status text DEFAULT NULL, p_stock_quantity integer DEFAULT NULL, p_listing_price numeric DEFAULT NULL, p_mark_price numeric DEFAULT NULL, p_description text DEFAULT NULL, p_card_image_url text DEFAULT NULL` | 0033 | 0033-token (p_admin_token→admins.session_token) | **无任何调用者** (前端/脚本/Edge/DB/Cron全部为空) | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 6 | public | **admin_confirm_pre_order** | `p_admin_token text, p_pre_order_id uuid, p_payment_method text DEFAULT 'mock_payment', p_transaction_id text DEFAULT NULL` | 0033 | 0033-token (p_admin_token→admins.session_token) | **无任何调用者** | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 7 | public | **approve_recharge** | `p_tx_id uuid, p_admin_uid uuid` | 0009 | 0009-platform_config (p_admin_uid→platform_config.admin_user_id比对) | admin-recharge.html | ✅✅ | **重写→v2**: 删除p_admin_uid→require_admin()+audit+幂等。前端删除p_admin_uid传参。 | B |
| 8 | public | **reject_recharge** | `p_tx_id uuid, p_admin_uid uuid, p_reason text DEFAULT '充值审核未通过'` | 0009 | 0009-platform_config (p_admin_uid→platform_config.admin_user_id比对) | admin-recharge.html | ✅✅ | **重写→v2**: 删除p_admin_uid→require_admin()+audit+幂等。前端删除p_admin_uid传参。 | B |
| 9 | public | **admin_disable_user** | `p_user_id uuid, p_reason text DEFAULT NULL` | 0019 | 0019-auth.uid()+email (auth.uid() AND email LIKE '%admin%') | admin-users.html | ✅✅ | **重写→v2**: 删除email LIKE→require_admin()+audit。前端不改传参(已是无认证参数)。 | C |
| 10 | public | **admin_enable_user** | `p_user_id uuid` | 0019 | 0019-auth.uid()+email (auth.uid() AND email LIKE '%admin%') | admin-users.html | ✅✅ | **重写→v2**: 删除email LIKE→require_admin()+audit。前端不改传参。 | C |
| 11 | public | **admin_verify_merchant** | `p_admin_id uuid, p_user_id uuid, p_merchant_name text, p_merchant_desc text DEFAULT '', p_merchant_badge text DEFAULT '✅'` | 0032 | 0032-admins.id (p_admin_id→admins.id + profiles.role + email LIKE '%admin%') | admin-merchant.html | ✅✅ | **重写→v2**: 删除p_admin_id→require_admin()+audit。前端删除p_admin_id: currentUser.id。 | C |
| 12 | public | **admin_revoke_merchant** | `p_admin_id uuid, p_user_id uuid` | 0032 | 0032-admins.id (p_admin_id→admins.id) | **无任何调用者** | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 13 | public | **admin_bulk_list_cards** | `p_admin_id uuid, p_cards json, p_live_session_id uuid DEFAULT NULL` | 0032 | 0032-admins.id (p_admin_id→admins.id) | **无任何调用者** | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 14 | public | **admin_create_sealed_product** | `p_admin_id uuid, p_name text DEFAULT 'New Product', p_product_type text DEFAULT 'sealed_box', p_sku text DEFAULT 'SKU-TEMP', p_listing_price numeric DEFAULT 100.00, ...共28个参数` | 0034d | 0032-admins.id (p_admin_id→admins.id) | **无任何调用者** | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 15 | public | **admin_update_sealed_product** | `p_admin_id uuid, p_product_id uuid DEFAULT NULL, ...共23个参数` | 0034c | 0032-admins.id (p_admin_id→admins.id) | **无任何调用者** | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 16 | public | **admin_confirm_sealed_order** | `p_admin_id uuid, p_order_id uuid DEFAULT NULL, p_tracking_no text DEFAULT NULL, p_shipping_carrier text DEFAULT NULL, p_action text DEFAULT 'confirm'` | 0034c | 0032-admins.id (p_admin_id→admins.id) | **无任何调用者** | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 17 | public | **admin_create_merchandise** | `p_admin_id uuid, p_name text DEFAULT 'New Merch', ...共20个参数` | 0034c | 0032-admins.id (p_admin_id→admins.id) | **无任何调用者** | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 18 | public | **admin_update_merchandise** | `p_admin_id uuid, p_merchandise_id uuid DEFAULT NULL, ...共17个参数` | 0034c | 0032-admins.id (p_admin_id→admins.id) | **无任何调用者** | ✅✅ | **停用**: REVOKE EXECUTE + 标记deprecated。Group D。 | D |
| 19 | public | **refresh_platform_card_prices** | `p_platform_card_id uuid DEFAULT NULL` | 0033 | **无认证** (任何人可调用) | **无任何调用者** | ✅✅ | **停用+加固**: REVOKE EXECUTE FROM anon/public + 标记deprecated。未来需要时可加require_admin()。 | D |
| 20 | public | **dev_is_team_admin** | `p_project_id uuid` | 未知 | SEC DEFINER无认证 | **无任何调用者** | ✅✅ | **DROP**: 无调用者，疑似开发调试，直接删除。 | D |

**对账验证**: 4(A)+2(B)+3(C)+11(D) = **20** ✅

---

## 三、Group A 拆分 (A1-A4)

### A1: admin-platform-login.html 重写

**改动**: 完全重写为 Supabase Auth 登录
**SQL**: 无 (认证流程改为前端 signInWithPassword)
**测试**: 登录→AdminAuth.requireAdmin()→成功跳转 / 失败提示

| 必删 | 必加 |
|------|------|
| `db.rpc('admin_login', {...})` | `db.auth.signInWithPassword({email, password})` |
| `localStorage.setItem('platformAdminToken', ...)` | `js/admin-auth.js` 引入 |
| `localStorage.setItem('platformAdminName', ...)` | `AdminAuth.requireAdmin()` 登录后校验 |
| `localStorage.setItem('platformAdminRole', ...)` | Supabase session 获取管理员身份 |
| 徽章 "独立管理员系统" | 删除或改为 "统一管理员系统" |
| `db.rpc('admin_logout', {p_token})` 调用 | 退出: `AdminAuth.logout()` + `db.auth.signOut()` |

**回滚**: 还原 admin-platform-login.html 单文件
**风险**: 旧 platform_admin 独立账号无法再登录。admin@cardrealm.top 已确认在 auth.users + profiles(role=super_admin)

### A2: admin-platform-publish.html token→AdminAuth

**改动**: 删除旧 token 读取和传递
**SQL**: 无 (前端改动先行，RPC 签名在 A3 变更)
**依赖**: A1 必须先完成 (否则无法登录进此页面)

| 必删 | 必加 |
|------|------|
| `let adminToken = localStorage.getItem('platformAdminToken')` | `js/admin-auth.js` 引入 |
| `if (!adminToken) { redirect }` 旧认证守卫 | `AdminAuth.requireAdmin()` 页面加载校验 |
| `localStorage.getItem('platformAdminName')` / `platformAdminRole` | Supabase session 获取显示名 |
| `p_admin_token: adminToken` (admin_publish_card RPC 参数) | 删除此参数，使用 admin_publish_card_v2 |
| `db.rpc('admin_logout', {p_token: adminToken})` | `AdminAuth.logout()` + `db.auth.signOut()` |

**特殊处理**: A2 部署时前端暂时调用 `admin_publish_card` (旧签名，仍传 p_admin_token 但值设为空字符串或 null)，A3 完成后前端切换到 `admin_publish_card_v2`。或者：A2 和 A3 在同一次部署中完成（前端+SQL同步切换），避免中间态。

**回滚**: 还原 admin-platform-publish.html 单文件

### A3: 商品发布/库存 RPC 重写 (仅重写有调用者的)

**有调用者的 RPC**: `admin_publish_card` (1个前端调用者)
**无调用者但同属0033系列**: admin_update_platform_card, admin_confirm_pre_order — 归入 Group D 停用

| 旧函数 | 新函数 | 改动 |
|--------|--------|------|
| `admin_publish_card(p_admin_token text, ...)` | `admin_publish_card_v2(p_name text, ...)` | 删除p_admin_token→require_admin()+status白名单+audit+幂等 |

**v2 RPC 统一要求**:
```sql
CREATE OR REPLACE FUNCTION public.admin_publish_card_v2(
  -- 删除 p_admin_token，保留全部业务参数
  p_name text, p_set_name text DEFAULT '', ...
)
RETURNS TABLE(success boolean, platform_card_id uuid, card_market_id uuid, final_price numeric, mark_price numeric, error text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  admin_uid UUID;
BEGIN
  admin_uid := require_admin();
  -- 业务参数校验 (name非空, listing_price>0, stock_quantity>0)
  -- 状态白名单 (card_category IN ('pokemon','yugioh','magic','onepiece','lorcana','other'))
  -- 幂等保护 (同name+set_name+category → 复用)
  -- INSERT platform_cards + card_market
  -- 审计日志 log_admin_action(admin_uid, 'publish_card', ...)
  RETURN NEXT;
EXCEPTION WHEN OTHERS THEN
  -- 独立BEGIN/EXCEPTION审计持久化
  BEGIN PERFORM log_admin_action(COALESCE(admin_uid, require_admin()), 'publish_card_ERROR', ...); EXCEPTION WHEN OTHERS THEN NULL; END;
  RETURN NEXT;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_publish_card_v2(...) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_publish_card_v2(...) TO authenticated;
```

**PostgREST 函数歧义防护**:
- 旧函数 ALTER RENAME TO `admin_publish_card_legacy`
- 新函数 `admin_publish_card_v2` (完整参数签名与旧函数不同: 无 p_admin_token)
- **PostgREST 通过函数名+参数签名区分调用**。由于 v2 参数签名不同 (少了 p_admin_token)，PostgREST 不会产生歧义
- 前端 `db.rpc('admin_publish_card_v2', {...})` 明确调用 v2
- **legacy 函数**: `REVOKE EXECUTE ON FUNCTION admin_publish_card_legacy(...) FROM PUBLIC, authenticated;` — 不再对任何角色开放

**回滚 SQL (0040_group_a_rollback.sql)**:
```sql
-- 回滚 A3
DROP FUNCTION IF EXISTS public.admin_publish_card_v2(...完整签名...);
ALTER FUNCTION public.admin_publish_card_legacy(...) RENAME TO admin_publish_card;
GRANT EXECUTE ON FUNCTION public.admin_publish_card(...) TO authenticated, anon;
```

### A4: 停用旧认证流程 (admin_login / verify_admin_token / admin_logout)

**前提**: A1-A3 全部通过验证
**操作**: 3 个旧认证函数不再有任何前端调用者

| 函数 | 处理 |
|------|------|
| `admin_login` | `ALTER FUNCTION admin_login(...) RENAME TO admin_login_legacy; REVOKE EXECUTE ON admin_login_legacy(...) FROM PUBLIC, authenticated;` |
| `verify_admin_token` | `ALTER FUNCTION verify_admin_token(...) RENAME TO verify_admin_token_legacy; REVOKE EXECUTE ... FROM PUBLIC, authenticated;` |
| `admin_logout` | `ALTER FUNCTION admin_logout(...) RENAME TO admin_logout_legacy; REVOKE EXECUTE ... FROM PUBLIC, authenticated;` |

**PostgREST 注意**: rename 后 PostgREST schema cache 需要刷新 (可通过 `NOTIFY pgrst, 'reload schema';` 触发，或等自动刷新周期)。如果 Supabase 不支持 NOTIFY，需等待约5分钟自动刷新。

**回滚**:
```sql
ALTER FUNCTION admin_login_legacy(...) RENAME TO admin_login;
GRANT EXECUTE ON admin_login(...) TO authenticated, anon;
-- 同理 verify_admin_token, admin_logout
```

---

## 四、Group B 实施顺序 (充值审批)

### B1: SQL 迁移 (0041)

| 旧函数 | 新函数 | 改动 |
|--------|--------|------|
| `approve_recharge(p_tx_id uuid, p_admin_uid uuid)` | `approve_recharge_v2(p_tx_id uuid)` | 删除p_admin_uid→require_admin()+audit+幂等(同一tx_id不可重复审批) |
| `reject_recharge(p_tx_id uuid, p_admin_uid uuid, p_reason text DEFAULT ...)` | `reject_recharge_v2(p_tx_id uuid, p_reason text DEFAULT ...)` | 删除p_admin_uid→require_admin()+audit+幂等 |

**v2 RPC 要求**:
- require_admin() 内部校验
- 幂等: tx_id 状态检查 (pending→approved 不可重复; pending→rejected 不可重复)
- 状态白名单: 仅 pending 状态可审批/拒绝
- audit: log_admin_action 记录审批/拒绝操作
- REVOKE FROM PUBLIC; GRANT TO authenticated
- 完整参数签名用于 ALTER/DROP/GRANT/REVOKE

**旧函数处理**: rename _legacy + REVOKE FROM authenticated/anon

### B2: 前端修改 (admin-recharge.html)

| 必删 | 必改 |
|------|------|
| `p_admin_uid: currentUser.id` (approve) | 删除此参数 |
| `p_admin_uid: currentUser.id` (reject) | 删除此参数 |
| `db.rpc('approve_recharge', ...)` | `db.rpc('approve_recharge_v2', {p_tx_id: txId})` |
| `db.rpc('reject_recharge', ...)` | `db.rpc('reject_recharge_v2', {p_tx_id: txId, p_reason: reason})` |

**回滚**: 还原 admin-recharge.html + SQL rollback (DROP v2 + 恢复旧函数名)

---

## 五、Group C 实施顺序 (用户/商户管理)

### C1: SQL 迁移 (0042)

| 旧函数 | 新函数 | 改动 |
|--------|--------|------|
| `admin_disable_user(p_user_id uuid, p_reason text DEFAULT NULL)` → RETURNS boolean | `admin_disable_user_v2(p_user_id uuid, p_reason text DEFAULT NULL)` → RETURNS jsonb | 删除email LIKE→require_admin()+audit+幂等(同一用户重复禁用返回已禁用) |
| `admin_enable_user(p_user_id uuid)` → RETURNS boolean | `admin_enable_user_v2(p_user_id uuid)` → RETURNS jsonb | 删除email LIKE→require_admin()+audit+幂等 |
| `admin_verify_merchant(p_admin_id uuid, p_user_id uuid, ...)` → RETURNS json | `admin_verify_merchant_v2(p_user_id uuid, p_merchant_name text, p_merchant_desc text DEFAULT '', p_merchant_badge text DEFAULT '✅')` → RETURNS jsonb | 删除p_admin_id→require_admin()+audit |

**注意**: admin_disable/enable_user 前端不传认证参数(函数内用 auth.uid()+email)，v2 签名不变(仅内部认证逻辑改变)。但返回类型从 boolean → jsonb，前端需适配返回值格式。

**PostgREST 注意**: v2 返回类型为 jsonb vs 旧 boolean — **参数签名相同但返回类型不同**。PostgREST 区分函数时只看名称+参数类型，不看返回类型。admin_disable_user(p_user_id uuid, p_reason text) 和 admin_disable_user_v2(p_user_id uuid, p_reason text) 参数签名相同 → **必须 rename 旧函数为 _legacy 后才能创建 v2，否则 PostgREST 会产生歧义**。

**旧函数处理**: rename _legacy + REVOKE FROM authenticated/anon

### C2: 前端修改

**admin-users.html** (已引入 AdminAuth.requireAdmin()):
- `db.rpc('admin_disable_user', ...)` → `db.rpc('admin_disable_user_v2', {p_user_id, p_reason})`
- `db.rpc('admin_enable_user', ...)` → `db.rpc('admin_enable_user_v2', {p_user_id})`
- 适配 jsonb 返回格式: `{success: true}` vs 旧 `true`

**admin-merchant.html** (已引入 AdminAuth.requireAdmin()):
- `db.rpc('admin_verify_merchant', {p_admin_id: currentUser.id, ...})` → `db.rpc('admin_verify_merchant_v2', {p_user_id, p_merchant_name, p_merchant_desc, p_merchant_badge})` (删除 p_admin_id)

**回滚**: 还原 2 个 HTML + SQL rollback

---

## 六、Group D 僵尸 RPC 停用方案

### 6.1 调用者确认 (已完成)

| 确认维度 | 检查结果 |
|----------|---------|
| 前端 HTML | grep 全部 admin*.html + 其他 html → 0 调用者 |
| Python/Node 脚本 | grep scripts/*.py → 0 调用者 |
| Edge Functions | grep supabase/functions/** → 0 调用者 |
| Cron (pg_cron) | cron.job 表不存在 → 0 调用者 |
| 数据库函数体内调用 | pg_proc.prosrc 搜索 → 0 调用者 |
| 外部 API | 无外部系统调用这些 RPC (Supabase 客户端库不直接调用) |

**结论**: 11 个 RPC + dev_is_team_admin = 12 个对象确认无任何调用者

### 6.2 停用方案 (0043)

**不是重写，而是停用**:

| 函数 | 处理 | 可回滚 |
|------|------|--------|
| admin_update_platform_card | `REVOKE EXECUTE ON FUNCTION admin_update_platform_card(p_admin_token text, p_platform_card_id uuid, ...) FROM PUBLIC, authenticated, anon;` + `COMMENT ON FUNCTION ... IS 'DEPRECATED: No callers. Retained for rollback.';` | ✅ GRANT EXECUTE TO authenticated, anon |
| admin_confirm_pre_order | 同上 | ✅ |
| admin_revoke_merchant | 同上 | ✅ |
| admin_bulk_list_cards | 同上 | ✅ |
| admin_create_sealed_product | 同上 | ✅ |
| admin_update_sealed_product | 同上 | ✅ |
| admin_confirm_sealed_order | 同上 | ✅ |
| admin_create_merchandise | 同上 | ✅ |
| admin_update_merchandise | 同上 | ✅ |
| refresh_platform_card_prices | `REVOKE EXECUTE ... FROM PUBLIC, authenticated, anon;` + COMMENT DEPRECATED | ✅ |
| dev_is_team_admin | `DROP FUNCTION public.dev_is_team_admin(p_project_id uuid);` | ✅ CREATE OR REPLACE 可恢复 |

**保留函数定义**: 不 DROP，仅 REVOKE + COMMENT。定义保留在 pg_proc 中，随时可 GRANT 恢复。

**观察期**: 停用后观察 2 周。若无异常 (Supabase 日志无相关 403 错误激增)，Phase 4 可最终 DROP。

### 6.3 回滚 SQL

```sql
-- 恢复所有停用函数的 EXECUTE 权限
GRANT EXECUTE ON FUNCTION public.admin_update_platform_card(...) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.admin_confirm_pre_order(...) TO authenticated, anon;
-- ... (共10个 REVOKE 函数恢复)
-- 重建 dev_is_team_admin
CREATE OR REPLACE FUNCTION public.dev_is_team_admin(p_project_id uuid) RETURNS boolean ...;
```

---

## 七、PostgREST 函数歧义防护

### 7.1 问题

PostgREST (Supabase 的 API 层) 通过函数名 + 参数类型列表区分 RPC 调用。如果同名函数存在不同参数签名 (overload)，PostgREST 根据前端传入的参数自动匹配。

**风险场景**:
1. 旧函数 rename 为 `_legacy` + 新函数 `_v2` → **不同名，不歧义** ✅
2. 旧函数保持原名 + 新函数 `_v2` → **不同名，不歧义** ✅
3. 最终阶段将 `_v2` rename 回原名，同时 `_legacy` 还存在 → **同名不同参数签名，可能歧义** ❌

### 7.2 防护策略

| 步骤 | 操作 | PostgREST 影响 |
|------|------|---------------|
| 创建期 | 旧→_legacy, 新→_v2 | 无歧义 (不同名) |
| 运行期 | 前端明确调用 _v2 | 无歧义 (PostgREST 按 name 匹配) |
| _legacy REVOKE | REVOKE EXECUTE FROM authenticated, anon | PostgREST 不暴露已 REVOKE 函数 |
| 最终清理 | DROP _legacy → v2 rename 回原名 | 需先 DROP _legacy 再 RENAME v2，不能同时存在同名不同签名 |

**关键规则**:
- **所有 ALTER/DROP/GRANT/REVOKE 必须使用完整函数参数签名** (如 `FUNCTION public.admin_publish_card(p_admin_token text, p_name text, ...)`)
- **rename 顺序**: 先 rename 旧函数为 _legacy，再 CREATE _v2，再 REVOKE _legacy
- **最终清理顺序**: 先 DROP _legacy，再 ALTER _v2 RENAME TO 原名
- **不得同时存在两个同名函数** (除非是合法 overload 且前端能区分)

### 7.3 0039 新 RPC 的 EXECUTE 权限修复 (遗留问题)

Phase 2 创建的 3 个新 RPC (admin_cancel_order/process_refund/resolve_dispute) 也对 anon 开放 EXECUTE (默认 GRANT TO PUBLIC)。**Phase 3 迁移中一并修复**:

```sql
-- 0040 中补修 0039 遗留权限问题
REVOKE EXECUTE ON FUNCTION public.admin_cancel_order(p_order_id uuid, p_reason text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_process_refund(p_order_id uuid, p_action text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_resolve_dispute(p_order_id uuid, p_resolution text, p_note text DEFAULT '') FROM PUBLIC;
-- 注意: 不从 authenticated REVOKE，这些函数需要 authenticated 角色调用
-- 但 require_admin() 内部已拦截 anon 和普通 user
```

---

## 八、每个 v2 RPC 统一要求 (确认清单)

| # | 要求 | 实现 | 验证方式 |
|---|------|------|----------|
| 1 | `SECURITY DEFINER` | 函数声明 | `\df+ public.xxx_v2` |
| 2 | `SET search_path = public, auth` | 函数声明 | `pg_get_functiondef()` 检查 |
| 3 | 内部调用 `require_admin()` | 函数体首行 | 非admin调用→FORBIDDEN |
| 4 | 不接受 admin token/id/uid 认证参数 | 参数签名 | 对账表确认 |
| 5 | UUID 数据库级校验 (IS NOT NULL + format) | 函数体内 | 传入 NULL UUID → 报错 |
| 6 | 状态白名单 | CASE/IF + IN list | 传入非法状态 → 报错 |
| 7 | 动作白名单 | 同上 | 传入非法动作 → 报错 |
| 8 | 幂等保护 | 先查状态再操作 | 同一参数两次 → 返回 {success:true, message:'already processed'} |
| 9 | 并发锁/原子操作 (必要时) | SELECT ... FOR UPDATE | 高并发场景 |
| 10 | 写 admin_audit_logs | log_admin_action() | 查 admin_audit_logs 表 |
| 11 | `REVOKE EXECUTE FROM PUBLIC` | 迁移SQL | has_function_privilege('anon', ..., 'EXECUTE') = false |
| 12 | `GRANT EXECUTE TO authenticated` | 迁移SQL | has_function_privilege('authenticated', ..., 'EXECUTE') = true |
| 13 | 独立回滚SQL | 每组提供 | DROP v2 + 旧恢复原名 |

---

## 九、测试矩阵

### 9.1 通用测试 (每组 12 项)

| # | 测试项 | 方法 | 预期 |
|---|--------|------|------|
| 1 | 未登录 (anon) 调用 → 拒绝 | `SET ROLE anon; SELECT xxx_v2(...)` | FORBIDDEN/error |
| 2 | 普通用户调用 → 拒绝 | `SET ROLE authenticated; SET LOCAL request.jwt.claims = '{"sub":"85b3b4dc..."}'; SELECT xxx_v2(...)` | FORBIDDEN/error |
| 3 | merchant 调用 → 拒绝 | `SET ROLE authenticated; SET LOCAL request.jwt.claims = '{"sub":"merchant_uuid"}'; SELECT xxx_v2(...)` | FORBIDDEN/error |
| 4 | admin 调用 → 成功 | `SET ROLE authenticated; SET LOCAL request.jwt.claims = '{"sub":"c48eed3c..."}'; SELECT xxx_v2(...)` | {success:true} |
| 5 | super_admin 调用 → 成功 | 同 #4 (c48eed3c = super_admin) | {success:true} |
| 6 | 认证参数不存在 | 函数签名无 p_admin_token/p_admin_id/p_admin_uid | 签名确认 |
| 7 | 伪造 admin id 无效 | 函数内部用 require_admin() = auth.uid() | 无外部admin id参数 |
| 8 | 审计日志写入 | `SELECT * FROM admin_audit_logs WHERE action='xxx'` | 有记录 |
| 9 | 幂等 (重复请求) | 同参数两次调用 | 第二次 {success:true, message:'already processed'} |
| 10 | 前端不读旧 token | grep platformAdminToken/p_admin_token/p_admin_uid/p_admin_id → 0 | 通过 |
| 11 | 登录后操作正常 | 实际页面操作 (发布卡牌/审批充值等) | 成功 |
| 12 | 登出后立即失效 | AdminAuth.logout() → 刷新 → requireAdmin() 失败 | 跳转登录页 |

### 9.2 Group 特殊测试

| Group | 额外测试 |
|-------|----------|
| **A1** | admin@cardrealm.top 可 Supabase Auth 登录 → requireAdmin() → 跳转 publish 页 |
| **A1** | 旧 platform_admin 账号无法登录 (不在 auth.users) |
| **A2** | admin-platform-publish.html 无 localStorage.getItem('platformAdminToken') |
| **A3** | admin_publish_card_v2 删除 p_admin_token → 前端 db.rpc('admin_publish_card_v2', {业务参数}) |
| **A4** | admin_login/verify_admin_token/admin_logout _legacy 函数 REVOKE authenticated/anon |
| **A4** | 尝试 db.rpc('admin_login', {...}) → 403 或 function not found |
| **B** | approve_recharge_v2 同 tx_id 重复审批 → {success:false, error:'already approved'} |
| **B** | reject_recharge_v2 也写审计日志 |
| **C** | admin_disable_user_v2 返回 jsonb {success:true} → 前端适配 |
| **C** | admin_verify_merchant_v2 不传 p_admin_id → 前端 {p_user_id, p_merchant_name, ...} |
| **D** | 10 个僵尸 RPC REVOKE authenticated/anon → anon 调用 403 |
| **D** | dev_is_team_admin DROP → 不存在于 information_schema |
| **补修** | admin_cancel_order/process_refund/resolve_dispute REVOKE FROM anon (0039遗留) |

---

## 十、每组回滚方案

| Group | 回滚范围 | 回滚操作 |
|-------|----------|----------|
| **A1** | admin-platform-login.html | 还原单文件 |
| **A2** | admin-platform-publish.html | 还原单文件 |
| **A3** | admin_publish_card_v2 + legacy | DROP v2 + legacy恢复原名 + GRANT authenticated/anon |
| **A4** | 3个认证函数legacy | legacy恢复原名 + GRANT authenticated/anon |
| **B** | approve/reject_v2 + legacy + admin-recharge.html | DROP v2 + legacy恢复 + 还原HTML |
| **C** | disable/enable/verify_v2 + legacy + 2 HTML | DROP v2 + legacy恢复 + 还原2 HTML |
| **D** | 10个REVOKE + 1个DROP | GRANT authenticated/anon + CREATE dev_is_team_admin |
| **补修** | 3个0039函数REVOKE anon | GRANT EXECUTE TO anon (恢复原状态) |

**每组独立回滚，不依赖其他组。**

---

## 十一、执行顺序总览

```
Phase 3 执行顺序:

A1: admin-platform-login.html 重写 (前端先行, 无SQL)
  │
  ├── 测试 A1 (登录/requireAdmin/跳转)
  │
A2: admin-platform-publish.html 改造 (前端, 无SQL)
  │
  ├── 测试 A2 (token删除/AdminAuth守卫/页面正常显示)
  │
A3: SQL 0040 (admin_publish_card_v2 + 0039权限补修 + legacy rename)
  │  + 前端同步切换 db.rpc('admin_publish_card_v2', ...)
  │
  ├── 测试 A3 (v2 RPC + 前端发布卡牌 + 权限补修)
  │
A4: SQL 0040 补充 (admin_login/verify_admin_token/admin_logout legacy + REVOKE)
  │
  ├── 测试 A4 (旧认证函数不可调用)
  │
B: SQL 0041 + admin-recharge.html 修改
  │
  ├── 测试 B (充值审批v2 + 幂等 + 审计)
  │
C: SQL 0042 + admin-users.html + admin-merchant.html 修改
  │
  ├── 测试 C (用户管理v2 + 商家认证v2 + 审计)
  │
D: SQL 0043 (僵尸RPC REVOKE + dev_is_team_admin DROP)
  │
  ├── 测试 D (僵尸函数403 + dev_is_team_admin不存在)
  │
全量回归 + Git commit + tag v0.9.6-admin-auth-phase3
  │
Phase 3 生产报告
```

---

## 十二、不在本阶段范围

- ❌ 不重写僵尸 RPC (仅停用，保留定义)
- ❌ 不删除 admins 旧表/数据 (保留只读)
- ❌ 不修改商品业务规则/定价/支付状态机
- ❌ 不修改普通用户页面
- ❌ 不修改 get_platform_card_list (公开查询保持无认证)
- ❌ 不处理 trg_* 触发器函数
- ❌ 不执行 SH-006B 数据库完整性迁移 (编号 0044-0046)
- ❌ 不执行 0037 图片上传安全 SQL

---

**⚠️ 等待王总审核确认。不实施任何代码或SQL改动。**
