# SH-003C Phase 3 部署与验收指令

> 代码已完成；以下操作需要在主仓库与 Supabase 线上执行。

## 基线

- 项目：`D:/codex/cardrealm/card-app/`
- 分支：`security-hardening`
- 上一标签：`v0.9.5-admin-auth-phase2`

## 1. 同步文件

将补丁包中的下列文件同步到主仓库：

- `admin-platform-login.html`
- `admin-platform-publish.html`
- `admin-recharge.html`
- `admin-merchant.html`
- `SECURITY_RULES.md`
- `TASK_INDEX.md`
- `SH-003C_Phase3_Report.md`
- `tests/sh003c-phase3-static-test.js`
- `supabase/migrations/MIGRATION_REGISTRY.md`
- `supabase/migrations/0040_admin_rpc_group_a.sql`
- `supabase/migrations/0041_admin_rpc_group_b.sql`
- `supabase/migrations/0042_admin_rpc_group_c.sql`
- `supabase/migrations/0043_admin_rpc_group_d_disable.sql`

## 2. 本地测试

```bash
node tests/sh003c-phase3-static-test.js
```

预期：`19 tests passed`。

## 3. 线上迁移（严格顺序）

### 0040 — 登录与平台发布

执行前备份：
- `admin_login/verify_admin_token/admin_logout` 函数定义和权限
- 旧 `admin_publish_card` 函数定义
- `platform_cards` 表结构

执行 `0040_admin_rpc_group_a.sql` 后测试：
- 未登录访问发布后台：拒绝
- user/merchant：拒绝
- admin/super_admin：Supabase Auth 登录成功
- 平台商品发布成功
- `platform_cards.auth_admin_id = auth.uid()`
- 旧 `platformAdminToken` 不再产生

### 0041 — 充值审核

执行后测试：
- user/merchant 调用：FORBIDDEN
- admin 批准 pending 充值：钱包只增加一次
- 重复批准：拒绝，不重复加款
- 拒绝 pending 充值：成功
- 已处理记录再次操作：拒绝
- `admin_audit_logs` 有记录

### 0042 — 用户与商户管理

执行后测试：
- user/merchant 调用：FORBIDDEN
- admin 禁用/启用用户：成功
- 管理员不能禁用自己
- admin 认证/撤销商户：成功
- 直接更新敏感字段仍被触发器拒绝
- 审计日志成功

### 0043 — 僵尸 RPC 停用

执行前再次确认没有前端、Edge Function、Cron 或脚本调用以下函数：
- admin_update_platform_card
- admin_confirm_pre_order
- admin_bulk_list_cards
- admin_create_sealed_product
- admin_update_sealed_product
- admin_confirm_sealed_order
- admin_create_merchandise
- admin_update_merchandise

执行后验证 `anon/authenticated` 调用均被拒绝。

## 4. 发布前端

部署修改后的 HTML/JS/文档，不得恢复旧 token 代码。

## 5. Git

```bash
git add admin-platform-login.html admin-platform-publish.html admin-recharge.html admin-merchant.html \
  SECURITY_RULES.md TASK_INDEX.md SH-003C_Phase3_Report.md DEPLOY_SH003_PHASE3.md \
  tests/sh003c-phase3-static-test.js supabase/migrations/
git commit -m "SH-003 Phase 3: migrate legacy admin auth and RPCs"
git tag v0.9.6-admin-auth-phase3
git push origin security-hardening
git push origin v0.9.6-admin-auth-phase3
```

## 6. 完成判定

只有 0040-0043 全部线上执行、角色矩阵与核心业务回归通过后，才将状态从：

`Code Complete / Pending Deploy`

改为：

`COMPLETE`
