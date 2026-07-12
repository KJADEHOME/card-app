# SH-003B: Admin Authentication Unification — FINAL IMPLEMENTATION PLAN

> **项目**: 卡域 CardRealm
> **阶段**: 最终实施计划 (Plan Only — 不修改代码)
> **日期**: 2026-07-13
> **状态**: 待王总审核
> **前置文档**: SH-003 设计方案 (已审核，提出修订要求)

---

## 一、目标架构 (确认)

```
Supabase Auth (email/password)
        │
        ▼
profiles.role = 'admin' (唯一管理员标识)
        │
        ├──▶ RLS Policy (最终权限边界 — 即使前端绕过，DB 层仍拒绝)
        │
        ├──▶ require_admin() RPC (SECURITY DEFINER — 所有管理操作统一入口)
        │       └──▶ admin_audit_logs (操作审计)
        │
        └──▶ js/admin-auth.js (前端统一认证模块 — 所有 admin 页面引入)
                └──▶ Fail-closed: 模块缺失则阻止页面运行
```

**六层防线**：
1. Supabase Auth — 身份认证
2. profiles.role — 角色判定
3. RLS — 数据库层权限边界
4. require_admin() — RPC 层权限校验
5. admin-auth.js — 前端层权限校验
6. admin_audit_logs — 操作审计追溯

---

## 二、实施阶段总览

```
Phase 1: 新增统一认证能力 (不破坏现有功能)
    │
    ▼
Phase 2: 修复三个 P0 (最高优先级)
    │
    ▼
Phase 3: 迁移所有后台页面到统一认证
    │
    ▼
Phase 4: 停用旧 admins 认证体系 (admins 表保留只读)
```

| 阶段 | 目标 | 修改范围 | 风险 | 回滚 |
|------|------|----------|------|------|
| Phase 1 | 创建新能力，不触碰现有代码 | 新建 2 文件 + 1 SQL 迁移 | 极低 — 纯新增 | DROP 新增对象 |
| Phase 2 | 堵住 3 个 P0 漏洞 | 4 个 HTML 文件 + SQL 迁移补充 RPC | 中 — 涉及 admin 页面行为变更 | 恢复旧 HTML (git revert) |
| Phase 3 | 全部 admin 页面统一认证 | 7 个 HTML 文件 | 中 — 短暂中断 admin 功能 | git revert + DROP 迁移 |
| Phase 4 | 废弃旧体系，不删数据 | SQL COMMENT + 前端删除旧引用 | 低 — 仅清理 | 恢复旧引用 |

---

## 三、Phase 1: 新增统一认证能力

> **原则**: 只新增，不修改现有代码。Phase 1 完成后，新能力和旧体系并存，互不干扰。

### 3.1 新建文件清单

| 文件 | 类型 | 内容 |
|------|------|------|
| `js/admin-auth.js` | 前端模块 | 统一管理员认证模块 |
| `supabase/migrations/0038_admin_auth_unification.sql` | SQL 迁移 | 审计表 + require_admin() + profiles RLS 加固 |

### 3.2 SQL 迁移 0038 内容

```sql
-- 0038_admin_auth_unification.sql
-- Phase 1: 新增统一认证能力 (不修改现有 RPC)

-- ============================================
-- Part 1: 创建审计日志表
-- ============================================
CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    admin_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id UUID,
    details JSONB DEFAULT '{}'::jsonb,
    ip_address TEXT,
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_admin_audit_logs_admin
    ON public.admin_audit_logs(admin_id, created_at DESC);
CREATE INDEX idx_admin_audit_logs_action
    ON public.admin_audit_logs(action, created_at DESC);

ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;

-- 仅管理员可读审计日志
CREATE POLICY "admin_audit_logs_read" ON public.admin_audit_logs
    FOR SELECT USING (
        EXISTS(SELECT 1 FROM public.profiles
               WHERE id = auth.uid() AND role = 'admin')
    );
-- 无 INSERT policy → 仅 service_role / SECURITY DEFINER RPC 可写

-- ============================================
-- Part 2: 创建统一权限校验函数
-- ============================================
CREATE OR REPLACE FUNCTION public.require_admin()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_role TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: 未登录';
    END IF;

    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;

    IF v_role IS NULL OR v_role != 'admin' THEN
        RAISE EXCEPTION 'FORBIDDEN: 需要管理员权限';
    END IF;

    RETURN v_uid;
END;
$$;

-- 授予所有认证用户调用权限 (函数内部自行校验)
GRANT EXECUTE ON FUNCTION public.require_admin() TO authenticated;

-- ============================================
-- Part 3: profiles.role RLS 加固
-- ============================================

-- 3.1 删除旧的 UPDATE 策略 (如果有)
-- 注意: 0036 生产 RLS 已执行，需先查看现有策略
-- DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;

-- 3.2 创建新 UPDATE 策略: 用户只能更新自己的 profile，但不能修改 role 字段
CREATE POLICY "profiles_update_own_no_role_change" ON public.profiles
    FOR UPDATE USING (auth.uid() = id)
    WITH CHECK (
        auth.uid() = id
        AND role = (
            SELECT p.role FROM public.profiles p
            WHERE p.id = auth.uid()
        )
    );
-- 效果: UPDATE 语句中如果包含 role 字段的新值与旧值不同，WITH CHECK 失败，操作被拒绝

-- ============================================
-- Part 4: 确保现有 admin@cardrealm.top 用户 role = 'admin'
-- ============================================
UPDATE public.profiles SET role = 'admin'
WHERE id IN (
    SELECT id FROM auth.users WHERE email = 'admin@cardrealm.top'
)
AND (role IS NULL OR role != 'admin');

-- ============================================
-- Part 5: 标记旧 admins 表为只读废弃 (不删除)
-- ============================================
COMMENT ON TABLE public.admins IS
    'DEPRECATED (SH-003B): 已迁移至 profiles.role。本表保留只读，用于历史审计日志。请勿通过此表认证。';
```

### 3.3 前端模块 js/admin-auth.js

```javascript
// js/admin-auth.js — 管理员统一认证模块
// 所有 admin 页面引入: <script src="js/risk-control.js"></script>
//                      <script src="js/admin-auth.js"></script>

const AdminAuth = {
    /**
     * 检查当前用户是否为管理员
     * @returns {Promise<{isAdmin: boolean, user: object|null, profile: object|null}>}
     */
    async check() {
        try {
            const { data: { session }, error } = await supabaseClient.auth.getSession();
            if (error || !session) {
                return { isAdmin: false, user: null, profile: null };
            }

            const { data: profile, error: pErr } = await supabaseClient
                .from('profiles')
                .select('id, role, username, email, merchant_name, merchant_badge')
                .eq('id', session.user.id)
                .single();

            if (pErr || !profile || profile.role !== 'admin') {
                return { isAdmin: false, user: session.user, profile: null };
            }

            return { isAdmin: true, user: session.user, profile };
        } catch (e) {
            console.error('AdminAuth.check error:', e);
            return { isAdmin: false, user: null, profile: null };
        }
    },

    /**
     * 要求管理员权限，否则跳转
     * 在每个 admin 页面 init() 首行调用
     * @returns {Promise<{user, profile}|null>} — null 表示已跳转
     */
    async requireAdmin() {
        const { isAdmin, user, profile } = await this.check();

        if (!user) {
            // 未登录 → 跳转登录页
            localStorage.setItem('redirectAfterLogin', window.location.href);
            window.location.href = 'login.html';
            return null;
        }

        if (!isAdmin) {
            // 已登录但非管理员 → 跳转首页
            console.warn('[AdminAuth] Unauthorized admin access:', user.id);
            window.location.href = 'index.html';
            return null;
        }

        return { user, profile };
    },

    /**
     * 登出 (清除 Supabase session + 跳转登录)
     */
    async logout() {
        await supabaseClient.auth.signOut();
        localStorage.removeItem('adminUid');           // 清理旧体系残留
        localStorage.removeItem('platformAdminToken');  // 清理旧体系残留
        window.location.href = 'login.html';
    }
};

// Fail-closed: supabaseClient 未加载 → 阻止页面
if (typeof supabaseClient === 'undefined') {
    document.body.replaceChildren(
        Object.assign(document.createElement('div'), {
            style: 'padding:40px;text-align:center;color:#e74c3c;',
            textContent: '安全模块加载失败，页面无法运行'
        })
    );
    throw new Error('Supabase client not loaded — admin page blocked');
}
```

### 3.4 Phase 1 验证项

| 验证项 | 方法 | 预期 |
|--------|------|------|
| require_admin() 对非管理员抛异常 | `SELECT require_admin();` 以普通用户身份 | `FORBIDDEN: 需要管理员权限` |
| require_admin() 对未登录抛异常 | `SELECT require_admin();` 匿名 | `UNAUTHORIZED: 未登录` |
| require_admin() 对管理员返回 UUID | `SELECT require_admin();` 以 admin@cardrealm.top | 返回 UUID |
| profiles.role 无法被普通用户修改 | 普通用户执行 `UPDATE profiles SET role='admin'` | RLS 拒绝 |
| admin_audit_logs 表仅管理员可读 | 普通用户 `SELECT * FROM admin_audit_logs` | 0 rows |
| admin-auth.js fail-closed | 删除 supabaseClient 引用 | 页面被替换 |
| 旧 admins 表仍可读 | `SELECT * FROM admins LIMIT 1` | 正常返回 |

### 3.5 Phase 1 回滚方案

```sql
-- 回滚 0038
DROP TABLE IF EXISTS public.admin_audit_logs CASCADE;
DROP FUNCTION IF EXISTS public.require_admin() CASCADE;
DROP POLICY IF EXISTS "profiles_update_own_no_role_change" ON public.profiles;
-- 删除 js/admin-auth.js
```

---

## 四、Phase 2: 修复三个 P0 (最高优先级)

> **原则**: 最小化修改范围，只堵漏洞。Phase 2 完成后，三个 P0 不再可被利用。

### 4.1 P0-1: 禁止 admin.html 自助绑定管理员

**当前漏洞** (admin.html):
- 第 125 行: `localStorage.getItem('adminUid')` — 客户端可篡改
- 第 128-146 行: `checkAdmin()` 仅比较 localStorage 中的 UID
- 第 262-281 行: 任何登录用户点"确定"即写入 `adminUid` 成为管理员

**修复方案**:

| 操作 | 具体修改 |
|------|----------|
| 删除 | 第 125 行 `getAdminUid()` 函数 |
| 替换 | 第 128-146 行 `checkAdmin()` → 调用 `AdminAuth.requireAdmin()` |
| 删除 | 第 262-281 行整个 `if (!getAdminUid())` 自助绑定块 |
| 新增 | `<script src="js/admin-auth.js"></script>` 引入 |
| 新增 | init 函数首行: `const adminCtx = await AdminAuth.requireAdmin(); if (!adminCtx) return;` |

**修复后流程**:
```
admin.html 加载
  → AdminAuth.requireAdmin()
    → Supabase Auth getSession()
      → 未登录 → 跳转 login.html
      → 已登录 → 查询 profiles.role
        → role ≠ 'admin' → 跳转 index.html
        → role = 'admin' → 加载管理后台
```

### 4.2 P0-2: 所有 admin 页面必须执行统一管理员检查

**受影响文件**:

| 文件 | 当前漏洞 | 修复内容 |
|------|----------|----------|
| admin-users.html (第 135-139 行) | init 仅检查 `db.auth.getUser()` | 替换为 `AdminAuth.requireAdmin()` |
| admin-recharge.html (第 154-163 行) | `checkAdmin()` 名不副实，只检查登录 | 替换为 `AdminAuth.requireAdmin()` |
| admin-orders.html (第 158-162 行) | init 仅检查 `db.auth.getUser()` | 替换为 `AdminAuth.requireAdmin()` |
| admin-merchant.html (第 229-239 行) | `email.includes('admin')` 备用检查 | 删除备用检查，替换为 `AdminAuth.requireAdmin()` |

**每个文件的修改模式**:
```javascript
// 修改前
async function init() {
    const { data: { user } } = await db.auth.getUser();
    if (!user) { window.location.href = 'login.html'; return; }
    loadData();
}

// 修改后
async function init() {
    const adminCtx = await AdminAuth.requireAdmin();
    if (!adminCtx) return;  // 已跳转
    currentUser = adminCtx.user;
    currentProfile = adminCtx.profile;
    loadData();
}
```

### 4.3 P0-3: admin-orders.html 禁止前端直接 update orders

**当前漏洞** (admin-orders.html):

| 位置 | 行号 | 操作 | 当前代码 |
|------|------|------|----------|
| resolveDispute | 484-492 | 争议裁决 | `db.from('orders').update({ status, dispute_resolution, ... })` |
| cancelOrder | 514-521 | 取消订单 | `db.from('orders').update({ status: 'cancelled', ... })` |
| processRefund | 536-542 | 退款处理 | `db.from('orders').update({ status: 'refunded', ... })` |

**修复方案**: 新增 3 个受控 RPC，前端调用 RPC 而非直接 update

#### SQL 迁移补充 (0038 Part 6 — 在 Phase 1 迁移基础上追加)

```sql
-- ============================================
-- Part 6: 新增管理操作 RPC (替代前端直接 update)
-- ============================================

-- 6.1 管理员取消订单
CREATE OR REPLACE FUNCTION public.admin_cancel_order(
    p_order_id UUID,
    p_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin_uid UUID;
    v_order RECORD;
BEGIN
    v_admin_uid := public.require_admin();

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    -- 状态校验: 只有 pending/paid 状态可取消
    IF v_order.status NOT IN ('pending', 'paid') THEN
        RETURN jsonb_build_object('success', false, 'error', '当前状态不可取消');
    END IF;

    UPDATE public.orders
    SET status = 'cancelled',
        cancel_reason = p_reason,
        cancelled_at = NOW()
    WHERE id = p_order_id;

    -- 审计日志
    INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
    VALUES (v_admin_uid, 'cancel_order', 'order', p_order_id,
            jsonb_build_object('reason', p_reason, 'prev_status', v_order.status));

    RETURN jsonb_build_object('success', true);
END;
$$;

-- 6.2 管理员处理退款
CREATE OR REPLACE FUNCTION public.admin_process_refund(
    p_order_id UUID,
    p_action TEXT  -- 'approve' | 'reject'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin_uid UUID;
    v_order RECORD;
    v_new_status TEXT;
BEGIN
    v_admin_uid := public.require_admin();

    -- action 白名单校验
    IF p_action NOT IN ('approve', 'reject') THEN
        RETURN jsonb_build_object('success', false, 'error', '无效操作');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    v_new_status := CASE WHEN p_action = 'approve' THEN 'refunded' ELSE 'paid' END;

    UPDATE public.orders
    SET status = v_new_status,
        refund_processed_at = NOW()
    WHERE id = p_order_id;

    INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
    VALUES (v_admin_uid, 'process_refund', 'order', p_order_id,
            jsonb_build_object('action', p_action, 'prev_status', v_order.status, 'new_status', v_new_status));

    RETURN jsonb_build_object('success', true);
END;
$$;

-- 6.3 管理员裁决争议
CREATE OR REPLACE FUNCTION public.admin_resolve_dispute(
    p_order_id UUID,
    p_resolution TEXT  -- 'buyer' | 'seller'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin_uid UUID;
    v_order RECORD;
    v_new_status TEXT;
BEGIN
    v_admin_uid := public.require_admin();

    IF p_resolution NOT IN ('buyer', 'seller') THEN
        RETURN jsonb_build_object('success', false, 'error', '无效裁决');
    END IF;

    SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '订单不存在');
    END IF;

    v_new_status := CASE WHEN p_resolution = 'buyer' THEN 'refunded' ELSE 'completed' END;

    UPDATE public.orders
    SET status = v_new_status,
        dispute_resolution = p_resolution,
        dispute_resolved_at = NOW(),
        dispute_resolved_by = v_admin_uid
    WHERE id = p_order_id;

    INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
    VALUES (v_admin_uid, 'resolve_dispute', 'order', p_order_id,
            jsonb_build_object('resolution', p_resolution, 'prev_status', v_order.status, 'new_status', v_new_status));

    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_cancel_order(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_process_refund(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_dispute(UUID, TEXT) TO authenticated;
```

#### 前端修改 (admin-orders.html)

| 位置 | 修改前 | 修改后 |
|------|--------|--------|
| 484-492 行 | `db.from('orders').update({...}).eq('id', orderId)` | `db.rpc('admin_resolve_dispute', { p_order_id: orderId, p_resolution: resolution })` |
| 514-521 行 | `db.from('orders').update({...}).eq('id', orderId)` | `db.rpc('admin_cancel_order', { p_order_id: orderId, p_reason: reason })` |
| 536-542 行 | `db.from('orders').update({...}).eq('id', orderId)` | `db.rpc('admin_process_refund', { p_order_id: orderId, p_action: action })` |

### 4.4 P0 补充: 删除默认密码明文

**admin-platform-login.html 修改**:

| 行号 | 操作 | 修改 |
|------|------|------|
| 36 | 修改 | 删除 `value="platform_admin"` |
| 37 | 修改 | 删除 `value="PlatformAdmin2026!"` |
| 42-46 | 删除 | 删除整个 `<div class="hint">` 默认凭据提示块 |

### 4.5 P0 补充: 删除 email.includes('admin') 备用检查

**admin-merchant.html 修改**:

| 行号 | 操作 | 修改 |
|------|------|------|
| 234 | 删除 | 删除 `if (!currentUser.email?.includes('admin'))` 整个备用检查块 |
| 229-239 | 替换 | 替换为 `const adminCtx = await AdminAuth.requireAdmin(); if (!adminCtx) return;` |

### 4.6 Phase 2 验证项

| 验证项 | 方法 | 预期 |
|--------|------|------|
| admin.html 无自助绑定弹窗 | 普通用户访问 admin.html | 直接跳转 index.html |
| admin-users.html 普通用户被拒 | 普通用户访问 | 跳转 index.html |
| admin-orders.html 普通用户被拒 | 普通用户访问 | 跳转 index.html |
| admin-recharge.html 普通用户被拒 | 普通用户访问 | 跳转 index.html |
| admin-merchant.html email 绕过失效 | email 含 "admin" 的普通用户访问 | 跳转 index.html |
| admin-orders.html 前端无直接 update | 搜索 `from('orders').update` | 0 结果 |
| admin_cancel_order RPC 普通用户调用失败 | 普通用户 RPC 调用 | `FORBIDDEN` 异常 |
| admin_resolve_dispute RPC 审计日志 | 管理员裁决后 | admin_audit_logs 有记录 |
| admin-platform-login 无明文密码 | 查看页面源码 | 无密码 value/hint |
| profiles.role 普通用户无法修改 | 普通用户 UPDATE profiles SET role='admin' | RLS 拒绝 |

### 4.7 Phase 2 回滚方案

```bash
# 前端回滚
git revert <phase2_commit>

# SQL 回滚
DROP FUNCTION IF EXISTS public.admin_cancel_order(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_process_refund(UUID, TEXT) CASCADE;
DROP FUNCTION IF EXISTS public.admin_resolve_dispute(UUID, TEXT) CASCADE;
```

---

## 五、Phase 3: 迁移所有后台页面到统一认证

> **原则**: 将剩余 admin 页面从旧认证体系迁移到 admin-auth.js。Phase 3 完成后，所有 admin 页面使用统一认证。

### 5.1 迁移清单

| 文件 | 当前体系 | 迁移目标 | 具体操作 |
|------|----------|----------|----------|
| admin-platform-login.html | A (admins 表) | Supabase Auth | 删除 `admin_login` RPC 调用 → 改用 `supabaseClient.auth.signInWithPassword()` |
| admin-platform-publish.html | A (token) | admin-auth.js | 删除 `localStorage.getItem('platformAdminToken')` → 引入 admin-auth.js |
| admin.html | B (localStorage) | admin-auth.js | Phase 2 已完成 |
| admin-users.html | C (仅登录) | admin-auth.js | Phase 2 已完成 |
| admin-orders.html | C (仅登录) | admin-auth.js | Phase 2 已完成 |
| admin-recharge.html | C+E (混合) | admin-auth.js | Phase 2 已完成 |
| admin-merchant.html | D (profiles+email) | admin-auth.js | Phase 2 已完成 |

### 5.2 admin-platform-login.html 迁移细节

**当前流程**:
```
输入 username + password → db.rpc('admin_login', {p_username, p_password})
→ 返回 session_token → localStorage.setItem('platformAdminToken', token)
→ 跳转 admin-platform-publish.html
```

**迁移后流程**:
```
输入 email + password → supabaseClient.auth.signInWithPassword({email, password})
→ Supabase Auth session
→ 查询 profiles.role === 'admin'
→ 跳转 admin-platform-publish.html (admin-auth.js 校验)
```

**具体修改**:
- 删除 username 输入框，改为 email 输入框
- 删除 `adminLogin()` 函数中的 `db.rpc('admin_login', ...)` 调用
- 替换为 `supabaseClient.auth.signInWithPassword()`
- 登录成功后查询 profiles.role，非 admin 则 signOut + 提示

### 5.3 admin-platform-publish.html 迁移细节

**当前流程**:
```
localStorage.getItem('platformAdminToken') → if (!token) 跳转 login
→ 所有 RPC 调用传 p_admin_token 参数
```

**迁移后流程**:
```
AdminAuth.requireAdmin() → if (!adminCtx) 跳转
→ 所有 RPC 调用去掉 p_admin_token 参数 (RPC 内部用 require_admin())
```

**具体修改**:
- 第 208 行: 删除 `let adminToken = localStorage.getItem('platformAdminToken')`
- 第 212-216 行: 替换为 `AdminAuth.requireAdmin()`
- 所有 `admin_publish_card`、`admin_update_platform_card` 等 RPC 调用: 删除 `p_admin_token` 参数

### 5.4 SQL 迁移补充 (0038 Part 7 — 重写旧 RPC)

```sql
-- ============================================
-- Part 7: 重写旧管理 RPC (去掉 p_admin_token 参数)
-- ============================================

-- 7.1 admin_publish_card
CREATE OR REPLACE FUNCTION public.admin_publish_card(
    p_card_name TEXT,
    p_set_name TEXT,
    p_rarity TEXT,
    p_image_url TEXT,
    p_listing_price NUMERIC,
    p_available_quantity INTEGER DEFAULT 1,
    p_category TEXT DEFAULT 'pokemon'
    -- 注意: 删除了 p_admin_token 参数
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_admin_uid UUID;
BEGIN
    v_admin_uid := public.require_admin();  -- 替代旧的 token 验证
    -- 业务逻辑不变...
    INSERT INTO public.admin_audit_logs (admin_id, action, target_type, details)
    VALUES (v_admin_uid, 'publish_card', 'platform_card',
            jsonb_build_object('card_name', p_card_name));
    RETURN jsonb_build_object('success', true);
END;
$$;

-- 7.2-7.7 同理重写以下函数 (删除 p_admin_token, 添加 require_admin()):
--   admin_update_platform_card
--   admin_confirm_pre_order
--   admin_cancel_pre_order
--   admin_adjust_stock
--   admin_disable_user (已有, 改 email LIKE → require_admin)
--   admin_enable_user (已有, 改 email LIKE → require_admin)
--   admin_verify_merchant (已有, 改 email LIKE → require_admin)
--   admin_revoke_merchant (已有, 改 email LIKE → require_admin)
--   admin_bulk_list_cards (已有, 改 email LIKE → require_admin)
--   approve_recharge (已有, 改 platform_config UUID → require_admin)
--   reject_recharge (已有, 改 platform_config UUID → require_admin)
```

### 5.5 Phase 3 验证项

| 验证项 | 方法 | 预期 |
|--------|------|------|
| admin-platform-login 用 Supabase Auth 登录 | 输入 admin@cardrealm.top + 密码 | 登录成功 |
| admin-platform-publish 不再读 token | 查看源码 | 无 `platformAdminToken` |
| 所有 RPC 不接受 p_admin_token 参数 | 调用时传 p_admin_token | 参数被忽略 |
| 所有旧 RPC 内部用 require_admin() | 普通用户调用 | `FORBIDDEN` |
| admin_disable_user 不再 email LIKE | 查看函数定义 | 无 `email LIKE` |
| approve_recharge 不再查 platform_config | 查看函数定义 | 无 `platform_config` 查询 |

### 5.6 Phase 3 回滚方案

```bash
git revert <phase3_commit>
# SQL 回滚需要恢复旧 RPC 函数定义 (从 git 历史中获取)
```

---

## 六、Phase 4: 停用旧 admins 认证体系

> **原则**: 不删除数据，只标记废弃 + 清理前端引用。admins 表保留只读。

### 6.1 废弃操作

| 操作 | 具体内容 |
|------|----------|
| admins 表 | Phase 1 已添加 COMMENT 标记废弃。保留数据，不删除 |
| admin_login RPC | 保留函数定义，前端不再调用。可选: 添加 `RAISE EXCEPTION 'DEPRECATED'` |
| admin_logout RPC | 同上 |
| verify_admin_token RPC | 同上 |
| platform_config.admin_user_id | DELETE 该行 (Phase 1 已处理) |
| localStorage.adminUid | 前端所有页面删除读写此 key 的代码 |
| localStorage.platformAdminToken | 前端所有页面删除读写此 key 的代码 |
| HTML 默认密码 | Phase 2 已删除 |
| email LIKE '%admin%' | Phase 3 已从所有 RPC 中删除 |
| email.includes('admin') | Phase 2 已从前端删除 |

### 6.2 admins 表保留策略

```sql
-- admins 表保持只读:
-- 1. 不删除表 (历史审计日志依赖)
-- 2. 不删除数据
-- 3. 可选: 添加 RLS 策略禁止 INSERT/UPDATE/DELETE (仅 service_role 可写)
CREATE POLICY "admins_readonly_denied" ON public.admins
    FOR INSERT USING (false);
CREATE POLICY "admins_readonly_denied_upd" ON public.admins
    FOR UPDATE USING (false);
CREATE POLICY "admins_readonly_denied_del" ON public.admins
    FOR DELETE USING (false);
-- 效果: 通过 anon/authenticated key 无法修改 admins 表
-- service_role 绕过 RLS 仍可操作 (紧急恢复用)
```

### 6.3 Phase 4 验证项

| 验证项 | 方法 | 预期 |
|--------|------|------|
| admins 表不可通过前端写入 | 普通用户 INSERT | RLS 拒绝 |
| admins 表数据完整 | `SELECT COUNT(*) FROM admins` | 与迁移前一致 |
| 前端无 adminUid 引用 | 搜索所有 HTML | 0 结果 |
| 前端无 platformAdminToken 引用 | 搜索所有 HTML | 0 结果 |
| 前端无明文密码 | 搜索所有 HTML | 0 结果 |
| RPC 无 email LIKE '%admin%' | 搜索所有 SQL | 0 结果 |
| admin_login RPC 不再被调用 | 搜索所有 HTML | 0 结果 |

---

## 七、完整文件修改清单

| 文件 | Phase | 操作 |
|------|-------|------|
| `js/admin-auth.js` | P1 | 新建 |
| `supabase/migrations/0038_admin_auth_unification.sql` | P1+P2+P3 | 新建 (分 Part 追加) |
| `admin.html` | P2 | 删除自助绑定 + 引入 admin-auth.js |
| `admin-users.html` | P2 | 引入 admin-auth.js + 替换 init |
| `admin-orders.html` | P2 | 引入 admin-auth.js + 替换 init + 3 处 RPC 替换 |
| `admin-recharge.html` | P2 | 引入 admin-auth.js + 替换 checkAdmin |
| `admin-merchant.html` | P2 | 引入 admin-auth.js + 删除 email 备用检查 |
| `admin-platform-login.html` | P2+P3 | P2: 删除默认密码; P3: 改用 Supabase Auth |
| `admin-platform-publish.html` | P3 | 引入 admin-auth.js + 删除 token 读取 |

---

## 八、不修改清单 (确认)

| 项目 | 说明 |
|------|------|
| 数据库业务表结构 | 不新增/删除业务表 (仅新增 admin_audit_logs) |
| RLS 核心策略 | 用户数据 auth.uid() = user_id 不变 |
| 定价引擎 | 不变 |
| 支付状态机 | 不变 (仅改操作入口从前端 update → RPC) |
| AI 识卡 | 不变 |
| Edge Functions | ai-scan / price-updater 不变 |
| Supabase 配置和密钥 | 不变 |
| admins 表数据 | 保留只读，不删除 |
| 非 admin 前端页面 | 不受影响 |

---

## 九、风险与缓解

| 风险 | 阶段 | 等级 | 缓解 |
|------|------|------|------|
| Phase 2 期间 admin 页面行为变更 | P2 | 中 | 低峰期部署；先部署 SQL (RPC) 再部署前端 |
| admin-orders RPC 状态校验遗漏 | P2 | 中 | RPC 内部校验订单状态白名单 |
| Phase 3 RPC 签名变更导致前端调用失败 | P3 | 中 | SQL 和前端同步部署 |
| admin@cardrealm.top 账号被锁 | 全局 | 中 | Supabase Dashboard 作为后门；设置第二管理员 |
| profiles RLS 变更影响普通用户 | P1 | 低 | SELECT 策略不变，仅 UPDATE 加 role 限制 |

---

## 十、实施时间线建议

| 阶段 | 预计工作量 | 建议执行顺序 |
|------|-----------|-------------|
| Phase 1 | 2 文件 + 1 SQL | 可独立执行，不影响线上 |
| Phase 2 | 5 HTML + SQL Part 6 | Phase 1 部署后立即执行 |
| Phase 3 | 2 HTML + SQL Part 7 | Phase 2 验证通过后执行 |
| Phase 4 | SQL RLS + 前端清理 | Phase 3 验证通过后执行 |

**部署顺序**: SQL 迁移 → 前端文件 → 验证 → 完成

---

*本文件为 SH-003B 最终实施计划，等待王总审核后进入实施阶段。*
