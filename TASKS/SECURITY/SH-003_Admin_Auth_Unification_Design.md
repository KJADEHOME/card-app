# SH-003: Admin Authentication Unification 设计方案

> **项目**: 卡域 CardRealm
> **阶段**: 设计方案 (Design Only — 不修改代码)
> **日期**: 2026-07-13
> **状态**: 待审核

---

## 一、现状分析

### 1.1 当前存在 6 套并行管理员认证体系

| 体系 | 认证方式 | 使用页面 | 服务端验证 | 安全等级 |
|------|----------|----------|------------|----------|
| **A. 独立管理员系统 (0033)** | admins 表 + pgcrypto 密码 + session_token | admin-platform-login, admin-platform-publish | verify_admin_token (token+过期+状态) | 较高 |
| **B. localStorage UID 自助绑定** | localStorage.getItem('adminUid') | admin.html | **无** | **P0 极低** |
| **C. 仅登录检查** | db.auth.getUser() 仅检查登录 | admin-users, admin-orders, admin-recharge | **无** | **P0 极低** |
| **D. profiles.role + email 备用** | profiles.role === 'admin' + email.includes('admin') | admin-merchant | profiles 查询 + email LIKE | 中 (有绕过) |
| **E. platform_config 硬编码 UUID** | config 表存储固定 UUID | admin-recharge (RPC) | UUID 精确匹配 | 低 (不灵活) |
| **F. email LIKE '%admin%'** | auth.users.email 字符串匹配 | 0019/0032 RPC 函数 | email LIKE '%admin%' | **P1 低** |

### 1.2 安全风险清单

| 风险ID | 等级 | 问题 | 影响 |
|--------|------|------|------|
| R-01 | **P0** | admin.html 自助绑定：任何登录用户点击"确定"即成为管理员 | 完全绕过管理员认证 |
| R-02 | **P0** | admin-users/orders/recharge 前端无管理员检查 | 任何注册用户可查看用户列表、订单、充值记录 |
| R-03 | **P0** | admin-orders.html 直接前端 db.from('orders').update() | 任何登录用户可取消订单、处理退款、解决争议 |
| R-04 | **P1** | 默认密码 platform_admin / PlatformAdmin2026! 明文在 HTML 中 | 查看源码即获取管理员凭据 |
| R-05 | **P1** | email LIKE '%admin%' 字符串匹配 | admin123@test.com 等邮箱可绕过 |
| R-06 | **P1** | admin-merchant.html email.includes('admin') 备用检查 | 同上 |
| R-07 | **P2** | 硬编码 UUID 45678987-... 在迁移文件中 | 账号删除后无法更换管理员 |
| R-08 | **P2** | 无统一登出机制 (体系B/C/D) | 公共电脑无法清除管理员权限 |
| R-09 | **P2** | 无操作审计日志 (仅体系A有) | 管理操作不可追溯 |
| R-10 | **P2** | profiles.role 可被用户自行修改 (无 RLS 限制) | 用户可自助提升为 admin |

---

## 二、设计目标

1. **单一认证入口**：全项目所有 admin 页面使用同一套认证逻辑
2. **消除双管理员体系**：废弃独立 admins 表，统一到 Supabase Auth + profiles.role
3. **删除默认密码**：不在任何前端代码或迁移文件中出现明文密码
4. **删除邮箱字符串判断**：彻底移除所有 `email LIKE '%admin%'` 和 `email.includes('admin')` 逻辑
5. **RLS 为最终权限边界**：即使前端被绕过，数据库层仍拒绝非授权操作
6. **操作可审计**：所有管理操作记录审计日志

---

## 三、统一架构设计

### 3.1 目标架构

```
┌─────────────────────────────────────────────────────┐
│                   统一管理员认证架构                    │
│                                                       │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────┐ │
│  │ Supabase    │───▶│ profiles     │───▶│ RLS     │ │
│  │ Auth        │    │ .role='admin'│    │ Policy  │ │
│  │ (email/pwd) │    │              │    │ (最终权限)│ │
│  └─────────────┘    └──────────────┘    └─────────┘ │
│         │                   │                  │     │
│         ▼                   ▼                  ▼     │
│  ┌─────────────┐    ┌──────────────┐    ┌─────────┐ │
│  │ Session     │    │ admin_audit  │    │ Edge    │ │
│  │ (Supabase   │    │ _logs        │    │ Function│ │
│  │  原生)      │    │ (新增)       │    │ (敏感操作)│ │
│  └─────────────┘    └──────────────┘    └─────────┘ │
└─────────────────────────────────────────────────────┘
```

### 3.2 认证流程

```
用户访问 admin 页面
       │
       ▼
┌──────────────────┐
│ 1. Supabase Auth │ ──▶ 未登录 → 跳转 login.html
│    getSession()  │
└────────┬─────────┘
         │ 已登录
         ▼
┌──────────────────┐
│ 2. 查询 profiles │ ──▶ role ≠ 'admin' → 跳转首页 + toast
│    .role         │
└────────┬─────────┘
         │ role = 'admin'
         ▼
┌──────────────────┐
│ 3. 加载管理后台   │
│    + 审计上下文  │
└──────────────────┘
         │
         ▼ (用户执行管理操作)
┌──────────────────┐
│ 4. RPC 调用      │ ──▶ RPC 内部: auth.uid() → profiles.role 校验
│    (SECURITY     │ ──▶ 记录 admin_audit_logs
│     DEFINER)     │ ──▶ RLS 作为最终防线
└──────────────────┘
```

### 3.3 profiles.role 安全加固

**当前问题**：profiles.role 无 RLS 限制，用户可自行 UPDATE。

**设计方案**：

```sql
-- profiles 表 RLS 策略 (修正)
-- 用户只能读自己的 profile (SELECT)
-- 用户不能修改 role 字段 (UPDATE 限制)
-- role 字段只能通过 service_role (Edge Function) 修改

CREATE POLICY "profiles_select_own" ON profiles
  FOR SELECT USING (auth.uid() = id OR EXISTS(
    SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'admin'
  ));
  -- admin 可以读所有 profiles

CREATE POLICY "profiles_update_own_limited" ON profiles
  FOR UPDATE USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND role = (SELECT role FROM profiles WHERE id = auth.uid())
    -- 用户不能修改自己的 role 字段
  );
  -- admin 修改其他用户的数据通过 Edge Function (service_role)
```

**关键点**：UPDATE 策略的 WITH CHECK 确保 role 值在更新前后一致，用户无法自行提升权限。

### 3.4 前端统一认证模块

新建 `js/admin-auth.js`，所有 admin 页面引入：

```javascript
// js/admin-auth.js — 管理员统一认证模块

const AdminAuth = {
  /**
   * 检查当前用户是否为管理员
   * @returns {Promise<{isAdmin: boolean, user: object|null, profile: object|null}>}
   */
  async check() {
    // 1. 检查 Supabase Auth session
    const { data: { session }, error } = await supabaseClient.auth.getSession();
    if (!session) {
      return { isAdmin: false, user: null, profile: null };
    }

    // 2. 查询 profiles.role
    const { data: profile, error: pErr } = await supabaseClient
      .from('profiles')
      .select('id, role, username, email, merchant_name, merchant_badge')
      .eq('id', session.user.id)
      .single();

    if (!profile || profile.role !== 'admin') {
      return { isAdmin: false, user: session.user, profile: null };
    }

    return { isAdmin: true, user: session.user, profile };
  },

  /**
   * 要求管理员权限，否则跳转
   * 在每个 admin 页面 init 时调用
   */
  async requireAdmin(redirectUrl = 'login.html') {
    const { isAdmin, user, profile } = await this.check();
    if (!user) {
      window.location.href = redirectUrl;
      return null;
    }
    if (!isAdmin) {
      // 记录未授权访问尝试 (可选)
      console.warn('Unauthorized admin access attempt:', user.id);
      window.location.href = 'index.html';
      return null;
    }
    return { user, profile };
  },

  /**
   * 登出
   */
  async logout() {
    await supabaseClient.auth.signOut();
    window.location.href = 'login.html';
  }
};

// Fail-closed: 如果模块加载失败，阻止页面执行
if (typeof supabaseClient === 'undefined') {
  document.body.replaceChildren(
    Object.assign(document.createElement('div'), {
      style: 'padding:40px;text-align:center;color:#e74c3c;',
      textContent: '安全模块加载失败，页面无法运行'
    })
  );
  throw new Error('Supabase client not loaded');
}
```

### 3.5 后端 RPC 统一权限校验

所有管理操作的 RPC 函数统一使用以下模式：

```sql
-- 统一管理员权限校验辅助函数
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
    RAISE EXCEPTION '未登录';
  END IF;

  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;

  IF v_role IS NULL OR v_role != 'admin' THEN
    RAISE EXCEPTION '需要管理员权限';
  END IF;

  RETURN v_uid;
END;
$$;

-- 所有管理 RPC 使用此模式：
CREATE OR REPLACE FUNCTION public.admin_disable_user(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_admin_uid UUID;
BEGIN
  v_admin_uid := public.require_admin();  -- 统一校验
  -- 业务逻辑...
  -- 记录审计日志
  INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
  VALUES (v_admin_uid, 'disable_user', 'user', p_user_id, jsonb_build_object('timestamp', NOW()));
  RETURN jsonb_build_object('success', true);
END;
$$;
```

### 3.6 审计日志表 (新增)

```sql
CREATE TABLE IF NOT EXISTS public.admin_audit_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    admin_id UUID REFERENCES auth.users(id) ON DELETE SET NULL NOT NULL,
    action TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id UUID,
    details JSONB DEFAULT '{}'::jsonb,
    ip_address TEXT,
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_admin_audit_logs_admin ON public.admin_audit_logs(admin_id, created_at DESC);
CREATE INDEX idx_admin_audit_logs_action ON public.admin_audit_logs(action, created_at DESC);

-- RLS: 仅管理员可读，仅 service_role 可写
ALTER TABLE public.admin_audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "admin_audit_logs_read" ON public.admin_audit_logs
  FOR SELECT USING (
    EXISTS(SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
  );
-- 无 INSERT policy → 仅 service_role 可写 (通过 SECURITY DEFINER RPC)
```

---

## 四、迁移影响分析

### 4.1 需修改的文件清单

| 文件 | 当前体系 | 目标体系 | 修改内容 |
|------|----------|----------|----------|
| **admin-platform-login.html** | A (独立系统) | Supabase Auth | 删除 admin_login RPC 调用，改为 Supabase Auth 登录；删除默认密码 input value |
| **admin-platform-publish.html** | A (独立系统) | Supabase Auth | 删除 platformAdminToken 读取，改为引入 admin-auth.js + requireAdmin() |
| **admin.html** | B (localStorage UID) | Supabase Auth | 删除 localStorage adminUid 逻辑 + 自助绑定，改为引入 admin-auth.js |
| **admin-users.html** | C (仅登录) | Supabase Auth | 引入 admin-auth.js + requireAdmin()；admin_disable/enable_user RPC 改用 require_admin() |
| **admin-orders.html** | C (仅登录) | Supabase Auth | 引入 admin-auth.js + requireAdmin()；直接 db.update 改为调用 RPC |
| **admin-recharge.html** | C+E (混合) | Supabase Auth | 引入 admin-auth.js + requireAdmin()；approve/reject_recharge RPC 改用 require_admin() |
| **admin-merchant.html** | D (profiles+email) | Supabase Auth | 删除 email.includes('admin') 备用检查；admin_verify/revoke_merchant RPC 改用 require_admin() |
| **js/admin-auth.js** | 不存在 | 新建 | 统一管理员认证模块 |
| **js/risk-control.js** | 无变化 | 无变化 | 不涉及 |
| **supabase/migrations/0038_*.sql** | 不存在 | 新建 | 迁移脚本 (见 4.3) |

### 4.2 需修改的 RPC 函数

| RPC 函数 | 当前迁移 | 当前校验方式 | 目标校验方式 |
|----------|----------|-------------|-------------|
| admin_login | 0033 | pgcrypto 密码验证 | **废弃** (改用 Supabase Auth) |
| admin_logout | 0033 | token 清除 | **废弃** (改用 Supabase Auth signOut) |
| verify_admin_token | 0033 | token+过期验证 | **废弃** |
| admin_publish_card | 0033 | p_admin_token 参数 | require_admin() |
| admin_update_platform_card | 0033 | p_admin_token 参数 | require_admin() |
| admin_confirm_pre_order | 0033 | p_admin_token 参数 | require_admin() |
| admin_cancel_pre_order | 0033 | p_admin_token 参数 | require_admin() |
| admin_adjust_stock | 0033 | p_admin_token 参数 | require_admin() |
| admin_disable_user | 0019 | email LIKE '%admin%' | require_admin() |
| admin_enable_user | 0019 | email LIKE '%admin%' | require_admin() |
| admin_verify_merchant | 0032 | email LIKE '%admin%' | require_admin() |
| admin_revoke_merchant | 0032 | email LIKE '%admin%' | require_admin() |
| admin_bulk_list_cards | 0032 | email LIKE '%admin%' | require_admin() |
| approve_recharge | 0009 | platform_config UUID | require_admin() |
| reject_recharge | 0009 | platform_config UUID | require_admin() |

### 4.3 数据库迁移方案 (0038)

```sql
-- 0038: 管理员认证统一迁移
-- 注意: 本文件为设计方案，待审核后执行

-- Part 1: 创建审计日志表
CREATE TABLE IF NOT EXISTS public.admin_audit_logs (...);

-- Part 2: 创建统一权限校验函数
CREATE OR REPLACE FUNCTION public.require_admin() ...;

-- Part 3: 修改 profiles RLS 策略
-- 3.1 删除旧策略
DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
-- 3.2 创建新策略 (admin 可读所有, 用户不能改 role)
CREATE POLICY "profiles_select_own_or_admin" ON ...;
CREATE POLICY "profiles_update_own_no_role_change" ON ...;

-- Part 4: 重写所有管理 RPC 函数
-- 4.1 admin_disable_user / admin_enable_user
-- 4.2 admin_verify_merchant / admin_revoke_merchant
-- 4.3 admin_bulk_list_cards
-- 4.4 approve_recharge / reject_recharge
-- 4.5 admin_publish_card / admin_update_platform_card
-- 4.6 admin_confirm_pre_order / admin_cancel_pre_order
-- 4.7 admin_adjust_stock

-- Part 5: 将现有 admin@cardrealm.top 用户设为 admin 角色
UPDATE public.profiles SET role = 'admin'
WHERE id IN (
  SELECT id FROM auth.users WHERE email = 'admin@cardrealm.top'
);

-- Part 6: 标记旧 admins 表为废弃 (不删除，保留审计日志)
COMMENT ON TABLE public.admins IS '已废弃 - 迁移至 profiles.role，保留用于历史审计日志';
ALTER TABLE public.admins SET (autovacuum_enabled = true);

-- Part 7: 清理 platform_config 中的 admin_user_id
DELETE FROM public.platform_config WHERE key = 'admin_user_id';
```

### 4.4 不变项

| 项目 | 说明 |
|------|------|
| Supabase Auth | 登录注册流程不变 |
| RLS 核心策略 | 用户数据 auth.uid() = user_id 不变 |
| 前端非 admin 页面 | 不受影响 |
| Edge Functions | ai-scan / price-updater 不变 |
| 数据库表结构 | 不新增业务表，仅新增 admin_audit_logs |
| 定价引擎 | 不变 |
| 支付状态机 | 不变 |

---

## 五、废弃清单

| 废弃项 | 处理方式 | 原因 |
|--------|----------|------|
| admins 表 (0033) | 保留数据，标记废弃 | 历史审计日志依赖 admin_id FK |
| admin_login RPC | 保留但前端不再调用 | 向后兼容，避免破坏依赖 |
| admin_logout RPC | 保留但前端不再调用 | 同上 |
| verify_admin_token RPC | 保留但前端不再调用 | 同上 |
| platform_config.admin_user_id | DELETE | 被 profiles.role 替代 |
| localStorage.adminUid | 前端删除 | 被 admin-auth.js 替代 |
| localStorage.platformAdminToken | 前端删除 | 被admin-auth.js 替代 |
| HTML 中的默认密码 | 前端删除 | 安全风险 |
| email LIKE '%admin%' | RPC 内删除 | 被 require_admin() 替代 |
| email.includes('admin') | 前端删除 | 被 profiles.role 替代 |

---

## 六、管理员账号初始化方案

### 6.1 问题

废弃 admins 表后，需要确保 admin@cardrealm.top 用户在 profiles 表中 role = 'admin'。

### 6.2 方案

1. **迁移脚本内执行** (0038 Part 5):
   ```sql
   UPDATE profiles SET role = 'admin'
   WHERE id IN (SELECT id FROM auth.users WHERE email = 'admin@cardrealm.top');
   ```

2. **后续管理员添加**：通过 Supabase Dashboard 或 Edge Function (service_role) 设置 profiles.role = 'admin'，不通过前端操作。

3. **紧急恢复**：如果唯一管理员账号被锁，通过 Supabase Dashboard 直接修改 profiles 表。

### 6.3 密码管理

- 不在任何代码/迁移文件中存储明文密码
- 管理员密码通过 Supabase Auth 的密码重置流程管理
- 初始管理员密码通过安全渠道 (如微信) 单独传递

---

## 七、风险评估

| 风险 | 等级 | 缓解措施 |
|------|------|----------|
| 迁移期间 admin 页面短暂不可用 | 中 | 在低峰期执行迁移；迁移脚本在一步内完成所有 RPC 替换 |
| profiles.role RLS 策略变更影响普通用户 | 低 | SELECT 策略放宽 (admin 可读所有)，UPDATE 策略仅限制 role 字段变更 |
| 旧 admins 表数据丢失 | 低 | 不删除表，仅标记废弃 |
| admin@cardrealm.top 账号被锁 | 中 | 保留 Supabase Dashboard 作为后门；可设置第二个管理员邮箱 |
| RPC 函数签名变更导致前端调用失败 | 中 | 迁移脚本内同步修改所有 RPC；前端在迁移后部署 |

---

## 八、执行顺序 (待审核确认后)

1. **SQL 迁移 0038** — 创建审计表 + require_admin() + 重写所有 RPC + 修正 profiles RLS
2. **新建 js/admin-auth.js** — 统一前端认证模块
3. **修改 7 个 admin HTML 页面** — 引入 admin-auth.js + 删除旧认证逻辑
4. **删除默认密码** — 清理 HTML 中的明文凭证
5. **测试** — 验证所有 admin 页面认证流程 + RPC 权限校验
6. **部署** — SQL 迁移 → 前端部署

---

## 九、与现有安全任务的关系

```
SH-001 (XSS) ────────── Batch 1-4 ✅  Batch 5 ⏳
SH-003 (Admin Auth) ─── 本文档 (设计阶段)
SH-004 (Image Upload) ─ ✅ 完成
SH-005 (Price Updater) ─ ✅ 完成
SH-006 (DB Integrity) ── 下一个 (设计阶段)
```

SH-003 实施后：
- 所有 admin 页面的 XSS 防护 (Batch 2 已完成) 继续有效
- admin-auth.js 将依赖 risk-control.js 的 fail-closed 机制
- profiles.role 的 RLS 加固是 SH-006 数据库完整性的一部分

---

*本文件为 SH-003 设计方案，等待王总审核后进入实施阶段。*
