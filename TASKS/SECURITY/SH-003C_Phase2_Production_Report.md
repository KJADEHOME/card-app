# SH-003C Phase 2 — 生产报告

> **项目**: 卡域 CardRealm
> **任务**: SH-003C Phase 2 — 修复 3 个 P0 管理员认证漏洞
> **日期**: 2026-07-13
> **Git**: commit `7aab7bb`, tag `v0.9.5-admin-auth-phase2`
> **前置**: Phase 1 (commit `f7aff8a`, tag `v0.9.4-admin-auth-phase1`) 已完成

---

## 一、执行概要

Phase 2 修复了 3 个 P0 级别安全漏洞 + 1 个补充修复，所有变更已线上执行并通过验证。

| 修复项 | 漏洞等级 | 状态 |
|--------|---------|------|
| P0-1: admin.html 自助绑定管理员 | P0 (严重) | ✅ 已修复 |
| P0-2: 4 个 admin 页面缺少管理员校验 | P0 (严重) | ✅ 已修复 |
| P0-3: admin-orders.html 前端直接 update orders | P0 (严重) | ✅ 已修复 |
| 补充: admin-platform-login.html 明文密码 | P0 (信息泄露) | ✅ 已修复 |

---

## 二、SQL 迁移 0039 — 线上执行

### 2.1 迁移文件
`supabase/migrations/0039_admin_orders_rpc.sql`

### 2.2 执行内容

| Part | 内容 | 状态 |
|------|------|------|
| Part 1 | 前置检查 (require_admin + admin_audit_logs + orders 表存在) | ✅ PASS |
| Part 2 | orders 表新增 5 列 (cancel_reason, cancelled_at, dispute_resolution, dispute_resolved_at, dispute_resolved_by) | ✅ 已执行 |
| Part 3 | admin_cancel_order(UUID, TEXT) RPC | ✅ 已创建 |
| Part 4 | admin_process_refund(UUID, TEXT) RPC | ✅ 已创建 |
| Part 5 | admin_resolve_dispute(UUID, TEXT) RPC | ✅ 已创建 |
| Part 6 | 对象验证 (3 函数全部存在) | ✅ PASS |

### 2.3 线上验证

```
3 RPC functions: ✅ admin_cancel_order, admin_process_refund, admin_resolve_dispute
5 new columns: ✅ cancel_reason, cancelled_at, dispute_resolution, dispute_resolved_at, dispute_resolved_by
```

### 2.4 RPC 安全设计

每个 RPC 函数均具有：
- `SECURITY DEFINER` + `SET search_path = public, auth`
- 内部调用 `require_admin()` 进行服务端权限校验
- 状态白名单校验 (如只有 pending/paid/disputed 状态可取消)
- 操作白名单校验 (approve/reject, buyer/seller/compromise)
- 审计日志写入 (独立 BEGIN/EXCEPTION 块确保持久化)
- `GRANT EXECUTE TO authenticated` (函数内部自行校验权限)

---

## 三、前端修复详情

### 3.1 P0-1: admin.html — 自助绑定管理员漏洞

**漏洞描述**: 任何已登录用户访问 admin.html 时，通过 `confirm()` 对话框点击"确定"即可将自己设为管理员（写入 `localStorage.adminUid`），无需服务端校验。

**修复内容**:
- 删除 `getAdminUid()` 函数
- 删除 `checkAdmin()` 函数（基于 localStorage 的伪认证）
- 删除自绑定代码块（confirm 对话框 + localStorage.setItem）
- 引入 `js/admin-auth.js`
- `loadData()` 首行调用 `AdminAuth.requireAdmin()`
- 使用 `AdminAuth.getSupabaseClient()` 替代直接 `createClient`

**修复后流程**:
```
admin.html → AdminAuth.requireAdmin()
  → Supabase Auth getSession() → 未登录 → 跳转 login.html
  → profiles.role 查询 → role ≠ admin → 跳转 index.html
  → require_admin() RPC → 服务端二次校验 → 通过 → 加载后台数据
```

### 3.2 P0-2: 4 个 admin 页面缺少管理员校验

| 文件 | 旧认证方式 | 漏洞 | 修复 |
|------|-----------|------|------|
| admin-users.html | `db.auth.getUser()` 仅检查登录 | 任何登录用户可管理用户 | `AdminAuth.requireAdmin()` |
| admin-orders.html | `db.auth.getUser()` 仅检查登录 | 任何登录用户可管理订单 | `AdminAuth.requireAdmin()` |
| admin-recharge.html | `checkAdmin()` 名不副实，仅检查登录 | 任何登录用户可审批充值 | `AdminAuth.requireAdmin()` |
| admin-merchant.html | `profile.role !== 'admin'` + `email.includes('admin')` 回退 | 邮箱含"admin"子串即可绕过 | `AdminAuth.requireAdmin()` |

### 3.3 P0-3: admin-orders.html 直接 db.from('orders').update()

**漏洞描述**: admin-orders.html 的 3 个管理操作函数直接在前端通过 `db.from('orders').update()` 修改订单状态，绕过了服务端业务逻辑和审计。

**修复内容**:

| 函数 | 旧代码 | 新代码 |
|------|--------|--------|
| `resolveDispute` | `db.from('orders').update({status, dispute_resolution, ...})` | `db.rpc('admin_resolve_dispute', {p_order_id, p_resolution})` |
| `cancelOrder` | `db.from('orders').update({status:'cancelled', cancel_reason, ...})` | `db.rpc('admin_cancel_order', {p_order_id, p_reason})` |
| `processRefund` | `db.from('orders').update({status, refund_processed_at})` | `db.rpc('admin_process_refund', {p_order_id, p_action})` |

每个 RPC 调用后检查 `data.success` 和 `error`，失败时显示错误信息。

### 3.4 补充: admin-platform-login.html 明文密码

**修复内容**:
- 删除 `value="platform_admin"` (用户名默认值)
- 删除 `value="PlatformAdmin2026!"` (密码默认值)
- 删除凭据提示文本块（含明文账号密码）

---

## 四、验证结果

### 4.1 前端静态分析 (9/9 PASS)

| 检查项 | 预期 | 结果 |
|--------|------|------|
| admin-auth.js 引入 5 个 admin 页面 | 5/5 | ✅ PASS |
| `from('orders').update` 残留 | 0 | ✅ PASS |
| `email.includes('admin')` 残留 | 0 | ✅ PASS |
| 明文密码 (`PlatformAdmin2026`) | 0 | ✅ PASS |
| `localStorage.adminUid` 引用 | 0 | ✅ PASS |
| 旧 `checkAdmin` 函数 | 0 | ✅ PASS |
| `db.auth.getUser` 直接认证 | 0 | ✅ PASS |
| `AdminAuth.requireAdmin()` 调用 | 5 | ✅ PASS |
| `AdminAuth.getSupabaseClient()` 使用 | 5 | ✅ PASS |

### 4.2 数据库 RPC 访问控制验证

| 测试 | 身份 | 预期 | 结果 |
|------|------|------|------|
| admin_cancel_order 普通用户 | user (85b3b4dc) | FORBIDDEN | ✅ `FORBIDDEN: Admin access required` |
| admin_cancel_order super_admin | super_admin (c48eed3c) | ORDER_NOT_FOUND (假UUID) | ✅ `{success: false, error: "ORDER_NOT_FOUND"}` |

### 4.3 修改文件清单

| 文件 | 修改类型 | 行数变化 |
|------|---------|---------|
| `admin.html` | 替换认证 + 删除自绑定 | -40 行 |
| `admin-users.html` | 替换认证 | +/- 5 行 |
| `admin-orders.html` | 替换认证 + 3处RPC替换 | +/- 30 行 |
| `admin-recharge.html` | 替换认证 | +/- 10 行 |
| `admin-merchant.html` | 替换认证 + 删除email检查 | -15 行 |
| `admin-platform-login.html` | 删除明文密码 | -4 行 |
| `supabase/migrations/0039_admin_orders_rpc.sql` | 新建 | +230 行 |

---

## 五、回滚方案

### 5.1 SQL 回滚
```sql
DROP FUNCTION IF EXISTS public.admin_cancel_order(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_process_refund(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_resolve_dispute(UUID, TEXT) CASCADE;
ALTER TABLE public.orders
    DROP COLUMN IF EXISTS cancel_reason,
    DROP COLUMN IF EXISTS cancelled_at,
    DROP COLUMN IF EXISTS dispute_resolution,
    DROP COLUMN IF EXISTS dispute_resolved_at,
    DROP COLUMN IF EXISTS dispute_resolved_by;
```

### 5.2 前端回滚
```bash
git revert 7aab7bb
```

---

## 六、Phase 2 完成状态

**✅ Phase 2 COMPLETE**

- 3 个 P0 漏洞 + 1 个补充修复全部完成
- SQL migration 0039 线上执行成功
- 9/9 前端静态检查 PASS
- 2/2 数据库 RPC 访问控制测试 PASS
- Git commit `7aab7bb` + tag `v0.9.5-admin-auth-phase2`

---

## 七、下一步建议

**✅ 建议进入 Phase 3。**

Phase 3 内容：
1. admin-platform-login.html: 从旧 admin_login RPC 迁移到 Supabase Auth signInWithPassword
2. admin-platform-publish.html: 从 localStorage platformAdminToken 迁移到 AdminAuth.requireAdmin()
3. SQL Part 7: 重写旧管理 RPC (删除 p_admin_token 参数，改用 require_admin())
4. 清理所有旧认证残留 (email LIKE '%admin%', platform_config UUID 查询)

---

*本报告为 SH-003C Phase 2 生产报告，所有变更已线上执行并通过验证。*
