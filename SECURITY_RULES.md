# SECURITY_RULES.md — 卡域 CardRealm 安全规则

> **版本**: 1.0 | **更新**: 2026-07-08 | **适用**: 卡域APP全项目

---

## 1. 安全架构总览

```
┌──────────────────────────────────────┐
│           安全分层                     │
│                                      │
│  Layer 1: 前端 (anon key + RLS)       │
│  Layer 2: Edge Functions (service_role│
│  Layer 3: 管理员 (独立认证体系)        │
│  Layer 4: 防刷 + 额度控制             │
└──────────────────────────────────────┘
```

---

## 2. RLS（Row Level Security）策略

### 2.1 核心原则

- **所有表必须启用 RLS** — 无例外
- **前端只用 anon key** — service_role 绝不出现在前端代码
- **RLS = 最小权限** — 用户只能操作自己的数据

### 2.2 已修复的安全问题（0036）

| 问题 | 原配置 | 修复后 |
|---|---|---|
| profiles "Allow all" | `qual = true` | `auth.uid() = id` |
| 支付写策略 | `qual = true` | service_role only |
| 商品写策略 | `qual = true` | service_role only |
| 存储桶无限制 | 无 file_size_limit | 设置 file_size_limit + allowed_mime_types |

### 2.3 RLS 模板规则

```sql
-- 用户数据：仅本人可读写
CREATE POLICY "Users can read own data" ON table_name
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own data" ON table_name
  FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 公开数据：所有人可读
CREATE POLICY "Anyone can read" ON table_name
  FOR SELECT USING (true);

-- 写操作：仅 service_role（通过 Edge Function）
-- 不设 INSERT/UPDATE/DELETE policy → 仅 service_role 可写
```

### 2.4 禁止的 RLS 配置

| # | 禁止 | 原因 |
|---|---|---|
| 1 | `WITH CHECK (true)` / `USING (true)` 用于写操作 | 任何人可写=无安全 |
| 2 | 前端直接用 service_role key | 完全绕过RLS |
| 3 | 禁用 RLS (`ALTER TABLE ... DISABLE ROW LEVEL SECURITY`) | 数据暴露 |

---

## 3. 认证体系

### 3.1 用户认证（Supabase Auth）

- Email/Phone 登录
- OAuth预留（Google/微信等）
- Session 管理: Supabase GoTrue 自动处理
- Token 存储: 前端 localStorage

### 3.2 管理员认证（独立系统 0033）

```
admins 表 (与 auth.users 隔离)
  ├─ username + password_hash (pgcrypto)
  ├─ session_token + token_expires_at
  └─ status (active/inactive)

认证流程:
  admin_login(username, password)
    → extensions.crypt(password, password_hash) 验证
    → 生成 session_token
    → 返回 token (前端存储)

权限验证:
  每次管理操作 → 检查 session_token + token_expires_at
  过期 → 拒绝操作
```

**管理员账号**:
- 平台管理员: `platform_admin` / `PlatformAdmin2026!`
- Supabase Auth 管理员: `admin@cardrealm.top` (UID: c48eed3c-...)

### 3.3 商家认证

- `profiles.role = 'merchant'`
- 认证: `admin_verify_merchant()` RPC
- 取消: `admin_revoke_merchant()` RPC
- 自营标识: `merchant_badge = '🛡️自营'`

---

## 4. 密钥管理

### 4.1 密钥分类与存放

| 密钥 | 类型 | 存放 | 前端可见 |
|---|---|---|---|
| Supabase anon key | 公开 | 前端 JS (supabase-client.js) | ✅ 设计即公开 |
| Supabase service_role | 私密 | 仅 Edge Function / SQL RPC | ❌ 绝不前端 |
| Supabase PAT | 私密 | deploy脚本环境变量 | ❌ |
| Gemini API Key | 私密 | Edge Function Secrets | ❌ |
| 管理员密码 | 私密 | admins 表 (pgcrypto哈希) | ❌ 仅哈希 |

### 4.2 绝对禁止

| # | 禁止 | 原因 |
|---|---|---|
| 1 | 前端代码中出现 service_role key | 完全绕过RLS，数据裸奔 |
| 2 | deploy_payload.json 含硬编码密钥 | Git历史泄露 |
| 3 | .env 文件提交到 Git | 密钥泄露 |
| 4 | 在 RPC 中返回 service_role key | 密钥泄露 |
| 5 | 在前端直接调用需要 service_role 的 RPC | 需通过 Edge Function |

---

## 5. 防刷机制

### 5.1 AI识卡防刷

| 机制 | 实现 |
|---|---|
| 图片去重 | `image_hash` 唯一索引 |
| 每日次数限制 | 50次/天 (ai_scan_logs 统计) |
| 积分扣费 | 识卡消耗积分 |

### 5.2 交易防刷

| 机制 | 实现 |
|---|---|
| 并发购买 | `FOR UPDATE` 行锁 |
| 库存冻结 | reserved_quantity + consignment 创建时冻结 |
| 挂单上限 | 预留控制 |

### 5.3 预约防刷

| 机制 | 实现 |
|---|---|
| 24h过期 | pre_orders 自动过期 |
| 价格锁定 | create_pre_order 锁定 mark_price |
| 库存扣减 | available_quantity 生成列计算 |

---

## 6. Supabase Storage 安全

### 6.1 存储桶配置

| 桶 | 用途 | file_size_limit | allowed_mime_types |
|---|---|---|---|
| card-images | 识卡图片 | 5MB | image/jpeg, image/png, image/webp |
| avatars | 用户头像 | 2MB | image/jpeg, image/png, image/webp |

### 6.2 存取规则

- 上传: 仅登录用户，仅本人目录
- 读取: 公开（卡牌图片需展示）
- 删除: 仅 service_role

---

## 7. Edge Function 安全

### 7.1 ai-scan 安全

- 请求验证: Authorization header (Bearer token)
- 文件大小验证: ≤5MB
- MIME类型验证: 仅 image/jpeg/png/webp
- Gemini API Key: 从 Secrets 读取，不硬编码
- 降级策略: gemini-2.5-flash → gemini-2.5-flash-lite

### 7.2 price-updater 安全

- Cron触发: Supabase pg_cron 或外部定时
- service_role 权限: 仅在函数内部使用
- 降级策略: 价格波动失败→保留原价

---

## 8. 前端安全

### 8.1 XSS 防护

- 所有用户输入展示前必须 HTML escape
- 不使用 innerHTML 直接插入用户内容
- 使用 textContent 或安全的模板函数

### 8.2 CSRF 防护

- Supabase Auth 自带 CSRF token
- Edge Function 验证 Authorization header

### 8.3 PWA 安全

- Service Worker 仅缓存自有域名资源
- manifest.json 不引用外部不可信资源
- HTTPS 强制（Cloudflare Pages 自动）

---

## 9. 安全检查清单（每次部署前）

- [ ] RLS 已启用所有表
- [ ] 无 `WITH CHECK (true)` 写策略
- [ ] service_role 不出现在前端代码
- [ ] deploy_payload.json 不含硬编码密钥
- [ ] 存储桶设 file_size_limit + allowed_mime_types
- [ ] Edge Function 验证 Authorization header
- [ ] RPC 使用 `SET search_path = ''`
- [ ] 管理员密码 pgcrypto 哈希存储
- [ ] .gitignore 包含 .env 和敏感文件
- [ ] Gemini API Key 在 Secrets 中而非代码中

---

## 10. 安全事件响应

| 等级 | 定义 | 处理 |
|---|---|---|
| P0 | 密钥泄露/数据裸奔 | 立即轮换密钥+修复，1h内响应 |
| P1 | RLS策略错误/认证绕过 | 4h内修复+部署 |
| P2 | 防刷失效/滥用增长 | 24h内修复 |

---

*本文件定义安全边界，安全变更需王总审批。任何安全红线违反=立即停止开发。*
