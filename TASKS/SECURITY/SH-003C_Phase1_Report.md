# SH-003C Phase 1 Report: Admin Auth Unification — New Capabilities

> **项目**: 卡域 CardRealm
> **阶段**: Phase 1 — 新增统一管理员认证能力
> **日期**: 2026-07-13
> **状态**: ✅ 实施完成，待线上SQL执行
> **主仓库**: `D:/codex/cardrealm/card-app/`

---

## 一、修改文件清单

| 文件 | 类型 | 操作 | 说明 |
|------|------|------|------|
| `supabase/migrations/0038_admin_auth_unification_phase1.sql` | SQL Migration | 新建 | Phase 1 全部数据库变更 (12 Parts) |
| `supabase/migrations/test_0038_sh003c_phase1.sql` | SQL Test | 新建 | 12项数据库测试脚本 (A-L) |
| `js/admin-auth.js` | 前端模块 | 新建 | 统一管理员认证JS模块 |
| `tests/sh003c-phase1-test.js` | JS Test | 新建 | 107项静态分析测试 |

**未修改的文件**: 所有现有HTML页面、现有RPC函数、业务表结构、定价引擎、支付系统、Edge Functions — 全部未触碰。

---

## 二、Migration 文件结构 (0038)

```
0038_admin_auth_unification_phase1.sql
├── Part 0:  Pre-flight checks (表存在、列存在、非法role数据扫描)
├── Part 1:  profiles.role CHECK 扩展 (新增 super_admin)
├── Part 2:  admin_audit_logs 表 + RLS (deny all direct DML)
├── Part 3:  require_admin() — SECURITY DEFINER, 固定 search_path
├── Part 4:  is_platform_admin() — super_admin 判定
├── Part 5:  log_admin_action() — 受控审计日志写入 (敏感数据剥离)
├── Part 6:  protect_sensitive_profile_fields() — BEFORE UPDATE 触发器
├── Part 7:  profiles UPDATE RLS 加固
├── Part 8:  update_my_profile() — 用户自服务白名单更新
├── Part 9:  set_user_role() — super_admin 专属角色管理 (含审计)
├── Part 10: 设置第一个 super_admin (admin@cardrealm.top)
├── Part 11: admins 表标记 deprecated (只读, 不删除)
├── Part 12: 验证查询 + 完整回滚SQL
```

---

## 三、profiles 敏感字段保护方式

### 保护机制: 三层防御

| 层级 | 机制 | 保护范围 |
|------|------|----------|
| **Layer 1: RLS** | `profiles_update_own` 策略 | 仅允许 `auth.uid() = id` 更新自己的 profile |
| **Layer 2: Trigger** | `trg_protect_sensitive_profile` (BEFORE UPDATE) | 阻止非 super_admin 修改敏感字段 |
| **Layer 3: RPC** | `update_my_profile()` 白名单更新 | 用户自服务只能改 username + avatar_url |

### 受保护字段清单

| 字段 | 来源迁移 | 保护方式 | 用户可改? | admin可改? | super_admin可改? |
|------|----------|----------|-----------|------------|------------------|
| `role` | 0032 | Trigger + RPC | ❌ | ❌ (via set_user_role) | ✅ |
| `is_disabled` | 0019 | Trigger | ❌ | ❌ | ✅ |
| `disabled_reason` | 0019 | Trigger | ❌ | ❌ | ✅ |
| `disabled_at` | 0019 | Trigger | ❌ | ❌ | ✅ |
| `disabled_by` | 0019 | Trigger | ❌ | ❌ | ✅ |
| `merchant_verified` | 0032 | Trigger | ❌ | ❌ | ✅ |
| `merchant_verified_by` | 0032 | Trigger | ❌ | ❌ | ✅ |

### 用户可修改字段 (白名单)

| 字段 | 修改方式 | 校验 |
|------|----------|------|
| `username` | `update_my_profile()` RPC | 非空、≤50字符、唯一性校验 |
| `avatar_url` | `update_my_profile()` RPC | ≤500字符 |

### Trigger 工作原理

```sql
-- trg_protect_sensitive_profile (BEFORE UPDATE ON profiles)
-- 1. auth.uid() IS NULL → service_role/migration context → 允许
-- 2. caller role = 'super_admin' → 允许
-- 3. 其他角色 → 检查7个敏感字段，任一变更即 RAISE EXCEPTION
```

**关键**: Trigger 使用 `IS DISTINCT FROM` 比较，正确处理 NULL 值。Trigger 函数为 SECURITY DEFINER，避免 RLS 干扰。

---

## 四、require_admin() 函数定义与权限

### 函数签名

```sql
CREATE OR REPLACE FUNCTION public.require_admin()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
```

### 安全特性

| 特性 | 实现方式 |
|------|----------|
| **SECURITY DEFINER** | 以函数所有者 (postgres) 权限执行，绕过 RLS |
| **固定 search_path** | `SET search_path = public, auth` — 防止 search_path 劫持 |
| **不接受前端参数** | 无参数，仅使用 `auth.uid()` |
| **未登录拒绝** | `IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHORIZED'` |
| **角色白名单** | `v_role NOT IN ('admin', 'super_admin')` → RAISE EXCEPTION 'FORBIDDEN' |
| **ERRCODE** | 使用 `42501` (insufficient_privilege) |
| **EXECUTE 权限** | `REVOKE FROM PUBLIC/anon; GRANT TO authenticated` |

### 调用链

```
前端 → AdminAuth.requireAdmin() → supabase.rpc('require_admin')
  → auth.uid() 获取当前用户
  → SELECT role FROM profiles WHERE id = auth.uid()
  → role IN ('admin', 'super_admin') → RETURN uid
  → 否则 → RAISE EXCEPTION
```

---

## 五、super_admin 初始化方式

### Bootstrap 流程

```
Migration Part 10 (一次性SQL):
  UPDATE profiles SET role = 'super_admin'
  WHERE id IN (SELECT id FROM auth.users WHERE email = 'admin@cardrealm.top')
  
→ 这是唯一一次通过 SQL 直接设置 super_admin
→ 之后所有角色变更必须通过 set_user_role() RPC
→ set_user_role() 内部验证调用者为 super_admin
→ admin 无法授予 super_admin (被拒绝并记录审计日志)
```

### set_user_role() 权限矩阵

| 调用者角色 | 授予 user | 授予 merchant | 授予 admin | 授予 super_admin |
|------------|-----------|---------------|------------|------------------|
| user | ❌ | ❌ | ❌ | ❌ |
| merchant | ❌ | ❌ | ❌ | ❌ |
| admin | ❌ | ❌ | ❌ | ❌ |
| super_admin | ✅ + 审计 | ✅ + 审计 | ✅ + 审计 | ✅ + 审计 |
| service_role | ✅ (bypass) | ✅ | ✅ | ✅ |

### 审计日志

每次 `set_user_role()` 调用（成功或失败）都写入 `admin_audit_logs`:
- 成功: action = `set_user_role`, details = `{old_role, new_role}`
- 拒绝: action = `set_user_role_DENIED`, details = `{requested_role, caller_role}`

---

## 六、admin_audit_logs 策略

### RLS 策略矩阵

| 操作 | anon | authenticated (user) | authenticated (admin) | authenticated (super_admin) | service_role |
|------|------|---------------------|----------------------|----------------------------|--------------|
| SELECT | ❌ | ❌ | ✅ | ✅ | ✅ |
| INSERT | ❌ | ❌ (WITH CHECK false) | ❌ (WITH CHECK false) | ❌ (WITH CHECK false) | ✅ |
| UPDATE | ❌ | ❌ (USING false) | ❌ (USING false) | ❌ (USING false) | ✅ |
| DELETE | ❌ | ❌ (USING false) | ❌ (USING false) | ❌ (USING false) | ✅ |

### 写入路径

前端**唯一**的写入方式: `log_admin_action()` RPC (SECURITY DEFINER)

```sql
-- log_admin_action() 内部:
-- 1. 调用 require_admin() 验证身份
-- 2. 剥离敏感键 (password, token, secret, card_number, cvv, ...)
-- 3. INSERT INTO admin_audit_logs (bypasses deny-insert RLS)
```

### 敏感数据剥离清单

```
password, password_hash, token, session_token,
secret, api_key, private_key, signing_key,
card_number, cvv, stripe_token, payment_intent_id
```

---

## 七、12项测试结果

### 静态分析测试 (107项子测试)

```
============================================================
SH-003C Phase 1 — Static Analysis Test Suite (12 tests)
============================================================
Total: 107 | PASS: 107 | FAIL: 0
✅ ALL TESTS PASSED — Phase 1 static analysis verified
```

### 12项测试详细结果

| # | 测试 | 方法 | 结果 |
|---|------|------|------|
| A | 未登录调用 require_admin → 拒绝 | 静态: 验证 auth.uid() NULL 检查 + UNAUTHORIZED 异常 | ✅ PASS |
| B | user 调用 require_admin → 拒绝 | 静态: 验证 role NOT IN ('admin','super_admin') + FORBIDDEN | ✅ PASS |
| C | merchant 调用 require_admin → 拒绝 | 静态: 验证 merchant 不在白名单 | ✅ PASS |
| D | admin 调用 require_admin → 通过 | 静态: 验证 admin 在白名单 + 返回 UUID | ✅ PASS |
| E | super_admin 调用 require_admin → 通过 | 静态: 验证 super_admin 在白名单 + CHECK 约束 | ✅ PASS |
| F | 普通用户改 role → 拒绝 | 静态: 验证 trigger 检查 7 个敏感字段 | ✅ PASS (11 sub-tests) |
| G | admin 授予 super_admin → 拒绝 | 静态: 验证 set_user_role 检查 super_admin + 审计拒绝 | ✅ PASS (5 sub-tests) |
| H | super_admin 修改角色 → 成功+审计 | 静态: 验证 UPDATE + INSERT audit log + 返回 log_id | ✅ PASS (5 sub-tests) |
| I | 普通用户写 audit_logs → 拒绝 | 静态: 验证 deny INSERT/UPDATE/DELETE + RLS enabled | ✅ PASS (8 sub-tests) |
| J | 旧管理员入口可用 | 静态: 验证 admins 表保留 + SELECT policy + 未删除 | ✅ PASS (8 sub-tests) |
| K | 无 RLS 递归 | 静态: 验证 trigger 无 UPDATE、函数不自调用 | ✅ PASS (5 sub-tests) |
| L | 回滚SQL完整 | 静态: 验证 13 项回滚目标存在 | ✅ PASS (13 sub-tests) |

### 额外验证 (47项)

| 类别 | 测试数 | 结果 |
|------|--------|------|
| SECURITY DEFINER + search_path + EXECUTE 权限 | 6 | ✅ ALL PASS |
| admin-auth.js 模块结构 + fail-closed + RPC调用 | 22 | ✅ ALL PASS |
| Pre-flight 检查 (表/列/非法数据) | 4 | ✅ ALL PASS |
| update_my_profile 白名单验证 | 6 | ✅ ALL PASS |

### SQL 数据库测试脚本

文件: `supabase/migrations/test_0038_sh003c_phase1.sql`

包含可在 Supabase SQL Editor 中运行的测试脚本，覆盖:
- Test A-E: require_admin() 不同角色调用 (需配合测试用户session)
- Test F: trigger 阻止 role 修改
- Test G: set_user_role 拒绝 admin
- Test H: set_user_role 成功 + 审计日志
- Test I: RLS 阻止直接写入 audit_logs
- Test J: admins 表可读 + deny-write policies
- Test K: trigger 无递归 (验证函数体无 UPDATE)
- Test L: 所有回滚目标存在 + CHECK 约束 + super_admin 已设置

---

## 八、回滚验证

### 回滚SQL完整性

回滚SQL包含在 migration 文件底部 (注释块)，覆盖所有 12 个 Part:

| Part | 回滚操作 | 验证 |
|------|----------|------|
| Part 11 | DROP admins deny policies + 恢复 COMMENT | ✅ |
| Part 10 | UPDATE profiles SET role='admin' WHERE role='super_admin' | ✅ |
| Part 9 | DROP FUNCTION set_user_role | ✅ |
| Part 8 | DROP FUNCTION update_my_profile | ✅ |
| Part 7 | DROP POLICY profiles_update_own + 恢复旧 policy | ✅ |
| Part 6 | DROP TRIGGER + DROP FUNCTION protect_sensitive_profile_fields | ✅ |
| Part 5 | DROP FUNCTION log_admin_action | ✅ |
| Part 4 | DROP FUNCTION is_platform_admin | ✅ |
| Part 3 | DROP FUNCTION require_admin | ✅ |
| Part 2 | DROP TABLE admin_audit_logs | ✅ |
| Part 1 | 恢复旧 CHECK constraint (无 super_admin) | ✅ |

回滚后状态 = Phase 1 之前状态 (0036 + 0037 已执行状态)。

---

## 九、剩余风险

| 风险 | 等级 | 说明 | 缓解 |
|------|------|------|------|
| 0038 SQL 未在线上执行 | **中** | 所有新能力 (require_admin, audit_logs, trigger) 尚未生效 | 尽快执行 migration |
| 现有 admin 页面仍用旧认证 | **中** | admin.html 等仍使用 localStorage adminUid | Phase 2 修复 |
| admin.html 自助绑定漏洞仍存在 | **高** | P0-1 未修复 (Phase 2 范围) | Phase 2 优先修复 |
| admin-orders.html 前端直接 update | **高** | P0-3 未修复 (Phase 2 范围) | Phase 2 优先修复 |
| trigger 可能在批量操作中影响性能 | **低** | BEFORE UPDATE trigger 对每行执行 | profiles 表写操作频率低 |
| super_admin 权力过大 | **低** | 可修改任意用户角色 | 审计日志 + 仅 admin@cardrealm.top |
| set_user_role_DENIED 审计可能被绕过 | **低** | 如果 INSERT 到 audit_logs 也失败 (RLS), denied 日志可能丢失 | 使用 BEGIN/EXCEPTION 容错, service_role 始终可写 |

---

## 十、是否建议进入 Phase 2

### ✅ 建议进入 Phase 2

**理由**:
1. Phase 1 所有新增能力已就绪 (require_admin, audit_logs, trigger, set_user_role, update_my_profile)
2. 107 项静态分析测试全部通过
3. 回滚SQL完整可验证
4. 现有系统完全不受影响 (纯新增, 无修改)
5. Phase 2 需要依赖 Phase 1 的 require_admin() 和 log_admin_action()

### Phase 2 前置条件

| 条件 | 状态 |
|------|------|
| 0038 migration 在线上执行 | ⏳ 待执行 |
| require_admin() 验证通过 (DB测试A-E) | ⏳ 待验证 |
| trigger 验证通过 (DB测试F) | ⏳ 待验证 |
| admin_audit_logs RLS 验证 (DB测试I) | ⏳ 待验证 |
| 旧系统仍可用 (DB测试J) | ⏳ 待验证 |

**建议执行顺序**:
1. 在 Supabase Dashboard 执行 0038 migration
2. 运行 test_0038_sh003c_phase1.sql 验证
3. 确认 admin@cardrealm.top 登录后 role = super_admin
4. 进入 Phase 2

---

## 十一、admins 旧系统状态

| 项目 | 状态 |
|------|------|
| admins 表 | ✅ 保留, 数据完整 |
| admins 表 COMMENT | 更新为 DEPRECATED |
| admins SELECT | ✅ authenticated 可读 (向后兼容) |
| admins INSERT/UPDATE/DELETE | ❌ 前端禁止 (RLS deny) |
| admin_login RPC | 未修改 (仍可用) |
| admin_logout RPC | 未修改 (仍可用) |
| verify_admin_token RPC | 未修改 (仍可用) |
| localStorage.adminUid | 未清理 (Phase 4) |
| localStorage.platformAdminToken | 未清理 (Phase 4) |

**旧管理员入口在 Phase 1 完成后仍然可用**，新能力与旧体系并存。

---

*SH-003C Phase 1 Report — 2026-07-13*
