# SH-003C Phase 3 — Code Complete Report

**状态：Code Complete / Pending Supabase Deployment**  
**基线：security-hardening @ 7aab7bb**

## 交付内容

### 前端
- `admin-platform-login.html`
  - 旧 `admin_login()` RPC 改为 `Supabase Auth.signInWithPassword()`
  - 登录后由 `AdminAuth.requireAdmin()` 进行客户端+服务端双重校验
  - 不再保存 `platformAdminToken/platformAdminName/platformAdminRole`
- `admin-platform-publish.html`
  - 使用 `AdminAuth.requireAdmin()`
  - 发布 RPC 不再发送 `p_admin_token`
  - 退出统一使用 `AdminAuth.logout()`
- `admin-recharge.html`
  - `approve_recharge/reject_recharge` 不再发送 `p_admin_uid`
- `admin-merchant.html`
  - `admin_verify_merchant` 不再发送 `p_admin_id`

### 数据库迁移
- `0040_admin_rpc_group_a.sql`
  - 新增 Auth 管理员发布 RPC overload
  - `platform_cards.auth_admin_id` 记录真实 Supabase Auth 管理员
  - 撤销旧 login/token/logout 对浏览器角色的 EXECUTE
- `0041_admin_rpc_group_b.sql`
  - 充值审批/拒绝改为 `require_admin()`
  - 行锁、状态校验、金额校验、审计日志
  - 撤销旧前端 admin UID overload
- `0042_admin_rpc_group_c.sql`
  - 用户禁用/启用、商户认证/撤销统一 `require_admin()`
  - 受控 RPC 上下文与敏感字段触发器协作
  - 撤销旧 admin ID overload
- `0043_admin_rpc_group_d_disable.sql`
  - 撤销 8 个无已知调用者旧 RPC 的 `PUBLIC/anon/authenticated` 执行权限
  - 保留函数定义，便于回滚和取证

## 静态测试

`node tests/sh003c-phase3-static-test.js`

- 19/19 PASS
- 4 个修改 HTML 内联脚本通过 `node --check`
- 旧前端 token/admin-id 参数引用：0

## 部署顺序

1. 备份函数定义与权限
2. 执行 `0040`
3. 验证管理员登录、平台发布、登出
4. 执行 `0041`
5. 验证充值批准/拒绝与幂等
6. 执行 `0042`
7. 验证用户禁用/启用、商户认证
8. 确认僵尸 RPC 无外部调用后执行 `0043`
9. 发布前端文件
10. 运行真实角色矩阵测试

## 尚未完成

- 未连接线上 Supabase，未执行 0040-0043
- 未完成真实 DB/RLS 测试
- 未提交 Git commit/tag

建议部署后标签：`v0.9.6-admin-auth-phase3`
