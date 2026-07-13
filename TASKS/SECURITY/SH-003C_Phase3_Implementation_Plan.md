# SH-003C Phase 3 — 旧平台管理员认证迁移实施计划

**日期**: 2026-07-13
**前置条件**: Phase 1 ✅ (0038 migration + require_admin()) · Phase 2 ✅ (3 P0 修复 + 0039 migration)
**Git 基线**: v0.9.5-admin-auth-phase2 (commit 7aab7bb)
**目标**: 将旧平台管理员登录与发布流程迁移到统一 AdminAuth 体系，重写全部旧管理 RPC，彻底移除 p_admin_token 依赖

---

## 一、前端迁移清单

### 1.1 admin-platform-login.html — 完全重写

**当前状态**: 使用旧 `admin_login` RPC (0033)，存储 `platformAdminToken` 到 localStorage
**目标**: Supabase Auth 登录 → AdminAuth.requireAdmin() → 进入后台

| 必须删除 | 原因 |
|----------|------|
| `db.rpc('admin_login', {...})` | 旧 admins 表 session_token 认证 |
| `localStorage.setItem('platformAdminToken', ...)` | 旧 token 存储 |
| `localStorage.setItem('platformAdminName', ...)` | 旧管理员信息缓存 |
| `localStorage.setItem('platformAdminRole', ...)` | 旧角色缓存 |
| 徽章 "独立管理员系统" | 不再是独立系统 |
| `db.rpc('admin_logout', {p_token})` 调用 | 旧 logout |

**改为**:
- 引入 `js/admin-auth.js` + `js/risk-control.js`
- 使用 Supabase Auth: `db.auth.signInWithPassword({email, password})`
- 登录后调用 `AdminAuth.requireAdmin()` 校验管理员身份
- 成功后跳转 `admin-platform-publish.html`
- 无管理员权限 → 提示 + 跳转首页
- 退出: `AdminAuth.logout()` + `db.auth.signOut()`

**风险**: 旧管理员账号 (platform_admin) 是 admins 表独立账号，不在 auth.users 中。需要将 admin@cardrealm.top 作为登录账号（已在 Phase 1 确认 UUID c48eed3c）。platform_admin 独立账号将被废弃。

### 1.2 admin-platform-publish.html — token → AdminAuth

**当前状态**: 从 localStorage 读 `platformAdminToken`，传 `p_admin_token` 给 RPC
**目标**: AdminAuth.requireAdmin() + 当前 Supabase session

| 必须删除 | 原因 |
|----------|------|
| `let adminToken = localStorage.getItem('platformAdminToken')` | 旧 token 读取 |
| `if (!adminToken)` 跳转登录页 | 旧认证守卫 |
| `localStorage.getItem('platformAdminName')` / `platformAdminRole` | 旧信息缓存 |
| `p_admin_token: adminToken` (RPC 参数) | 旧 token 传递 |
| `db.rpc('admin_logout', {p_token: adminToken})` | 旧 logout |

**改为**:
- 引入 `js/admin-auth.js`
- 页面加载: `AdminAuth.requireAdmin()` (fail-closed)
- 获取 Supabase 客户端: `AdminAuth.getSupabaseClient()`
- 发布卡牌: `db.rpc('admin_publish_card', {所有业务参数，无 p_admin_token})`
- 获取列表: `db.rpc('get_platform_card_list', {...})` (不变，无认证参数)
- 退出: `AdminAuth.logout()` + `db.auth.signOut()`

**风险**: RPC 签名变更 `admin_publish_card` 删除 p_admin_token 参数，新函数用 `require_admin()` 内部校验。需要同步部署 SQL + 前端。

---

## 二、旧 RPC 完整列表 (20 个)

### 2.1 按 4 种旧认证模式分类

| 模式 | 函数 | 旧认证方式 | 前端调用者 |
|------|------|-----------|-----------|
| **A: 0033 token** | `admin_login` | admins 表用户名/密码 → session_token | admin-platform-login.html |
| | `verify_admin_token` | 查 admins.session_token | 无前端调用 (内部辅助) |
| | `admin_logout` | 删除 admins.session_token | admin-platform-publish.html |
| | `admin_publish_card` | p_admin_token → admins.session_token | admin-platform-publish.html |
| | `admin_update_platform_card` | p_admin_token → admins.session_token | **无前端调用** |
| | `admin_confirm_pre_order` | p_admin_token → admins.session_token | **无前端调用** |
| **B: 0009 platform_config** | `approve_recharge` | p_admin_uid → platform_config.admin_user_id | admin-recharge.html |
| | `reject_recharge` | p_admin_uid → platform_config.admin_user_id | admin-recharge.html |
| **C: 0019 auth.uid() email** | `admin_disable_user` | auth.uid() AND email LIKE '%admin%' | admin-users.html |
| | `admin_enable_user` | auth.uid() AND email LIKE '%admin%' | admin-users.html |
| **D: 0032/0034 admins.id** | `admin_verify_merchant` | p_admin_id → admins.id / profiles.role + email | admin-merchant.html |
| | `admin_revoke_merchant` | p_admin_id → admins.id | **无前端调用** |
| | `admin_bulk_list_cards` | p_admin_id → admins.id | **无前端调用** |
| | `admin_create_sealed_product` | p_admin_id → admins.id | **无前端调用** |
| | `admin_update_sealed_product` | p_admin_id → admins.id | **无前端调用** |
| | `admin_confirm_sealed_order` | p_admin_id → admins.id | **无前端调用** |
| | `admin_create_merchandise` | p_admin_id → admins.id | **无前端调用** |
| | `admin_update_merchandise` | p_admin_id → admins.id | **无前端调用** |

### 2.2 无认证函数 (2 个)

| 函数 | 认证方式 | 说明 | 前端调用者 |
|------|----------|------|-----------|
| `refresh_platform_card_prices` | **无认证** | 任何人可调用刷新价格 | **无前端调用** |
| `get_platform_card_list` | **无认证** | 公开查询平台卡牌列表 | admin-platform-publish.html + platform-store.html |

### 2.3 已重写 (Phase 2, 跳过)

- `admin_cancel_order` (0039) ✅ require_admin()
- `admin_process_refund` (0039) ✅ require_admin()
- `admin_resolve_dispute` (0039) ✅ require_admin()

### 2.4 辅助函数 (跳过)

- `dev_is_team_admin` — 无前端调用，疑似开发调试用，标记 DEPRECATED
- `trg_mark_platform_stock` / `trg_mark_platform_sale` / `trg_update_platform_cards_timestamp` — 触发器，不涉及认证
- `require_admin` / `is_platform_admin` / `log_admin_action` — Phase 1 新建，已统一

---

## 三、按业务分组方案

### Group A: 商品发布与库存 (6 个 RPC + 2 个前端页面)

**前端**:
1. `admin-platform-login.html` — 重写为 Supabase Auth 登录
2. `admin-platform-publish.html` — token → AdminAuth + 删除 p_admin_token

**RPC 重写**:
| 旧函数 | 新函数 | 改动 |
|--------|--------|------|
| `admin_login` | **废弃** → Supabase Auth signInWithPassword | 完全替代 |
| `verify_admin_token` | **废弃** → require_admin() | 完全替代 |
| `admin_logout` | **废弃** → db.auth.signOut() | 完全替代 |
| `admin_publish_card` | `admin_publish_card_v2` | 删除 p_admin_token → require_admin() + audit |
| `admin_update_platform_card` | `admin_update_platform_card_v2` | 删除 p_admin_token → require_admin() + audit |
| `admin_confirm_pre_order` | `admin_confirm_pre_order_v2` | 删除 p_admin_token → require_admin() + audit |

**保留不变**:
- `get_platform_card_list` — 公开查询，保持无认证（但有 3 个前端调用者）
- `refresh_platform_card_prices` — 改为 require_admin() 保护（无前端调用者）

**风险与回滚**:
- **风险**: admin-platform-login.html 完全重写，旧 platform_admin 独立账号将无法登录
- **缓解**: admin@cardrealm.top 已在 auth.users + profiles(role=super_admin)，Phase 1 已验证
- **回滚**: 旧 admin_login/admin_logout/admin_publish_card 保留原名 + 标记 _legacy，新函数用 _v2 后缀。前端回滚只需还原 2 个 HTML 文件。SQL 回滚: DROP _v2 函数 + REVOKE EXECUTE

---

### Group B: 订单与充值 (2 个 RPC + 1 个前端页面)

**前端**:
- `admin-recharge.html` — 删除 p_admin_uid 参数，RPC 内部用 require_admin()

**RPC 重写**:
| 旧函数 | 新函数 | 改动 |
|--------|--------|------|
| `approve_recharge` | `approve_recharge_v2` | 删除 p_admin_uid → require_admin() + audit |
| `reject_recharge` | `reject_recharge_v2` | 删除 p_admin_uid → require_admin() + audit |

**风险与回滚**:
- **风险**: 充值审核是资金操作，需要特别注意幂等性
- **回滚**: 旧函数保留 + _legacy 后缀。前端回滚: 还原 admin-recharge.html。SQL 回滚: DROP _v2 + 旧函数恢复原名

---

### Group C: 用户与商户管理 (5 个 RPC + 2 个前端页面)

**前端**:
- `admin-users.html` — 删除 p_admin_uid 传递（函数已用 auth.uid()），改为 require_admin() 内部校验
- `admin-merchant.html` — 删除 p_admin_id: currentUser.id 参数

**RPC 重写**:
| 旧函数 | 新函数 | 改动 |
|--------|--------|------|
| `admin_disable_user` | `admin_disable_user_v2` | 删除 email LIKE '%admin%' → require_admin() + audit |
| `admin_enable_user` | `admin_enable_user_v2` | 删除 email LIKE '%admin%' → require_admin() + audit |
| `admin_verify_merchant` | `admin_verify_merchant_v2` | 删除 p_admin_id → require_admin() + audit |
| `admin_revoke_merchant` | `admin_revoke_merchant_v2` | 删除 p_admin_id → require_admin() + audit (无前端调用) |
| `admin_bulk_list_cards` | **标记 DEPRECATED** → require_admin() | 无前端调用，直接 DROP 后重建 |

**风险与回滚**:
- **风险**: admin_disable_user 是敏感操作（禁用用户），需要审计日志
- **回滚**: 旧函数保留 _legacy。前端回滚: 还原 2 个 HTML 文件

---

### Group D: 密封产品与周边 (6 个 RPC，无前端调用者)

**前端**: 无改动（这些 RPC 没有前端调用者）

**RPC 重写**:
| 旧函数 | 新函数 | 改动 |
|--------|--------|------|
| `admin_create_sealed_product` | `admin_create_sealed_product_v2` | 删除 p_admin_id → require_admin() + audit |
| `admin_update_sealed_product` | `admin_update_sealed_product_v2` | 删除 p_admin_id → require_admin() + audit |
| `admin_confirm_sealed_order` | `admin_confirm_sealed_order_v2` | 删除 p_admin_id → require_admin() + audit |
| `admin_create_merchandise` | `admin_create_merchandise_v2` | 删除 p_admin_id → require_admin() + audit |
| `admin_update_merchandise` | `admin_update_merchandise_v2` | 删除 p_admin_id → require_admin() + audit |
| `refresh_platform_card_prices` | `refresh_platform_card_prices_v2` | 新增 require_admin() 保护 |

**dev_is_team_admin**: DROP (无任何调用者)

**风险与回滚**:
- **风险**: 极低——无前端调用者，仅 SQL 层改动
- **回滚**: DROP _v2 + 旧函数恢复原名

---

## 四、迁移策略与命名规范

### 4.1 双版本并存方案

| 步骤 | 操作 | 说明 |
|------|------|------|
| 1 | 旧函数 → `_legacy` 后缀 | `admin_publish_card` → `admin_publish_card_legacy` |
| 2 | 创建 `_v2` 新函数 | 使用 require_admin()，无 p_admin_token / p_admin_id / p_admin_uid |
| 3 | 前端切换到 `_v2` | admin-platform-publish.html 使用 admin_publish_card_v2 |
| 4 | 验证通过后 | 下一版本将 _v2 改回原名 + DROP _legacy |
| 5 | 最终清理 (Phase 4) | DROP admin_login / verify_admin_token / admin_logout (认证流程已废弃) |

### 4.2 每个 _v2 RPC 必须包含

```sql
CREATE OR REPLACE FUNCTION public.xxx_v2(...)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  admin_uid UUID;
BEGIN
  -- 1. 统一认证
  admin_uid := require_admin();

  -- 2. 业务参数白名单校验 (如 status/action)

  -- 3. 业务逻辑

  -- 4. 审计日志
  PERFORM log_admin_action(admin_uid, 'xxx', ...);

  -- 5. 返回
  RETURN json_build_object('success', true, ...);

EXCEPTION WHEN OTHERS THEN
  -- 审计日志持久化 (独立 BEGIN/EXCEPTION)
  BEGIN
    PERFORM log_admin_action(admin_uid, 'xxx_ERROR', ...);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$$;
```

### 4.3 EXECUTE 权限收紧

所有 `_v2` 函数: `REVOKE EXECUTE ON FUNCTION xxx_v2 FROM PUBLIC; GRANT EXECUTE ON FUNCTION xxx_v2 TO authenticated;`

---

## 五、SQL 迁移文件规划

| 文件 | 内容 | Group |
|------|------|-------|
| `0040_admin_rpc_group_a.sql` | 6 个旧函数 rename _legacy + 6 个 _v2 新建 + 2 个认证废弃标记 + refresh_platform_card_prices_v2 | A |
| `0041_admin_rpc_group_b.sql` | 2 个旧函数 rename _legacy + 2 个 _v2 新建 | B |
| `0042_admin_rpc_group_c.sql` | 5 个旧函数 rename _legacy + 5 个 _v2 新建 + dev_is_team_admin DROP | C |
| `0043_admin_rpc_group_d.sql` | 6 个旧函数 rename _legacy + 6 个 _v2 新建 | D |

每个文件包含:
- 前置检查 (确认旧函数存在)
- 旧函数 rename
- 新 _v2 函数创建
- REVOKE/GRANT EXECUTE
- 回滚 SQL (DROP _v2 + 旧函数恢复原名)

---

## 六、测试矩阵

### 6.1 通用测试 (每组 12 项)

| # | 测试项 | 方法 |
|---|--------|------|
| 1 | 未登录调用 → 拒绝 | `SET ROLE anon; SELECT xxx_v2(...)` |
| 2 | 普通用户调用 → 拒绝 | `SET ROLE authenticated; SET LOCAL request.jwt.claims = '{"sub":"85b3b4dc...","role":"authenticated"}'; SELECT xxx_v2(...)` |
| 3 | merchant 调用 → 拒绝 | `SET ROLE authenticated; SET LOCAL request.jwt.claims = '{"sub":"merchant_uuid","role":"authenticated"}'; SELECT xxx_v2(...)` |
| 4 | admin 调用 → 成功 | `SET ROLE authenticated; SET LOCAL request.jwt.claims = '{"sub":"c48eed3c...","role":"authenticated"}'; SELECT xxx_v2(...)` |
| 5 | super_admin 调用 → 成功 | 同 #4 (admin@cardrealm.top = super_admin) |
| 6 | p_admin_token/p_admin_id/p_admin_uid 参数不存在 | `SELECT xxx_v2(业务参数)` — 无认证参数 |
| 7 | 伪造 admin id 无效 | 不传 admin_id, 函数内部用 require_admin() = auth.uid() |
| 8 | 审计日志写入 | 查 admin_audit_logs 表 |
| 9 | 重复请求幂等 | 同一参数两次调用 |
| 10 | 前端不再读取旧 token | grep platformAdminToken / p_admin_token |
| 11 | 登录后发布商品正常 | admin-platform-publish.html 实际操作 |
| 12 | 登出后后台立即失效 | AdminAuth.logout() → 刷新 → 跳转登录 |

### 6.2 Group 特殊测试

| Group | 额外测试 |
|-------|----------|
| A | admin@cardrealm.top 可登录并发布卡牌；旧 platform_admin 账号无法登录 |
| B | 充值审批幂等 (同一 tx_id 不可重复审批)；拒绝充值也写审计日志 |
| C | 禁用用户也写审计日志；商家认证也写审计日志 |
| D | 6 个僵尸 RPC 的 _v2 版本 require_admin() 正确；dev_is_team_admin 已 DROP |

---

## 七、执行顺序

```
Step 1: 创建 SQL 迁移文件 (0040-0043)
Step 2: 线上执行 Group A (0040) — 最关键，有前端依赖
Step 3: 修改 admin-platform-login.html + admin-platform-publish.html
Step 4: 测试 Group A (12 + 特殊)
Step 5: 线上执行 Group B (0041) + 修改 admin-recharge.html
Step 6: 测试 Group B
Step 7: 线上执行 Group C (0042) + 修改 admin-users.html + admin-merchant.html
Step 8: 测试 Group C
Step 9: 线上执行 Group D (0043)
Step 10: 测试 Group D
Step 11: 全量回归验证 (前端 + RPC + 审计日志)
Step 12: Git commit + tag v0.9.6-admin-auth-phase3
Step 13: 输出 Phase 3 生产报告
```

---

## 八、回滚方案总览

| 场景 | 操作 |
|------|------|
| Group A 失败 | DROP _v2 函数 + 前端还原 2 个 HTML + 旧函数恢复原名 |
| Group B 失败 | DROP _v2 + 旧函数恢复原名 + 前端还原 admin-recharge.html |
| Group C 失败 | DROP _v2 + 旧函数恢复原名 + 前端还原 admin-users/admin-merchant.html |
| Group D 失败 | DROP _v2 + 旧函数恢复原名 (无前端依赖) |
| 全部失败 | 每组独立回滚，不影响其他组 |

---

## 九、不修改清单

- ❌ 商品业务规则 (定价、三级价格等)
- ❌ 支付状态机 (orders 状态流转)
- ❌ 定价引擎 (price_updater Edge Function)
- ❌ AI识卡 (card-identify Edge Function)
- ❌ 普通用户页面 (index.html, marketplace.html 等)
- ❌ admins 旧数据 (保留只读，不删除)
- ❌ 已重写的 3 个 RPC (admin_cancel_order/process_refund/resolve_dispute)
- ❌ get_platform_card_list (保持无认证公开查询)
- ❌ trg_* 触发器函数

---

## 十、预期工作量

| 部分 | 新/改文件数 | SQL 对象数 |
|------|-------------|-----------|
| Group A 前端 | 2 HTML 重写 | 6 _legacy rename + 7 _v2 新建 + 2 废弃标记 |
| Group B 前端 | 1 HTML 修改 | 2 _legacy rename + 2 _v2 新建 |
| Group C 前端 | 2 HTML 修改 | 5 _legacy rename + 5 _v2 新建 + 1 DROP |
| Group D 前端 | 0 | 6 _legacy rename + 6 _v2 新建 |
| 测试脚本 | 1 py (4 Group) | - |
| SQL 迁移文件 | 4 (0040-0043) | - |
| 报告 | 1 md | - |

**总计**: 5 HTML 修改/重写 + 4 SQL 迁移 + 1 测试脚本 + 1 报告

---

**⚠️ 等待确认后开始实施。**
