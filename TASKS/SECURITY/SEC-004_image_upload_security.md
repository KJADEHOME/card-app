# SEC-004: Image Upload Security

> **状态**: Completed ✅ | **优先级**: P0 | **模块**: SECURITY

---

## 1. 问题概述

图片上传流程存在多重安全缺陷，从前端到后端到存储均缺少关键验证：

### P0 — 立即修复

| # | 问题 | 位置 | 影响 |
|---|---|---|---|
| 1 | **risk-control.js 不存在** | 项目根 | 无统一安全模块 |
| 2 | **Edge Function 无身份认证** | ai-scan index.ts/js | 任何人可无限制调用AI接口 |
| 3 | **API密钥硬编码** | ai-scan + scripts/fetch-tcgdex-prices.js | 密钥泄露到Git |
| 4 | **无MIME类型验证(服务端)** | Edge Function | 可上传任意文件 |
| 5 | **无文件大小限制(服务端)** | Edge Function | 内存耗尽攻击 |
| 6 | **无速率限制** | Edge Function | API费用滥用 |

### P1 — 近期修复

| # | 问题 | 位置 | 影响 |
|---|---|---|---|
| 7 | 前端无文件大小验证(除sell.html) | index/collection/publish.html | 大文件直接发送 |
| 8 | 前端无文件类型验证 | 所有上传页面 | 非图片文件可提交 |
| 9 | 无EXIF数据清理 | index.html | GPS隐私泄露 |
| 10 | 无图片压缩/缩放 | index.html | 传输效率低 |
| 11 | Storage无MIME/扩展名限制 | SQL配置 | 可存储恶意文件 |
| 12 | scan-history.html XSS | scan-history.html | 注入攻击 |
| 13 | service_role密钥在代码中 | scripts/fetch-tcgdex-prices.js | 绕过所有RLS |

---

## 2. 修改计划

### Phase 1: risk-control.js 统一安全模块 (新建)

```
js/risk-control.js
├── validateImageFile(file)       ← 前端: MIME/大小/扩展名白名单
├── compressImage(base64, maxKB)  ← 前端: 压缩+缩放
├── stripExifData(base64)         ← 前端: EXIF清理
├── generateImageHash(base64)     ← 前端: 去重hash
└── escapeHtml(str)               ← 全站: XSS防护
```

**安全参数**:
- 文件大小上限: 5MB (前端预检) / base64 ≤ 6.5MB (服务端)
- MIME白名单: image/jpeg, image/png, image/webp
- 扩展名白名单: jpg, jpeg, png, webp
- 图片最大像素: 2048×2048
- 压缩质量: 0.85 JPEG

### Phase 2: Edge Function 安全加固 (修改)

```
supabase/functions/ai-scan/index.ts
├── JWT认证: 验证 Authorization Bearer token
├── base64大小限制: ≤ 6.5MB
├── MIME类型验证: 解析base64 data URL前缀
├── Magic bytes检查: JPEG(FFD8FF)/PNG(89504E47)/WebP(52494646)
├── 速率限制: 依赖数据库 ai_scan_logs (50次/天)
├── API密钥: 仅 Deno.env.get(), 无硬编码fallback
└── CORS: 限制为 cardrealm.top 域名
```

### Phase 3: Storage策略加固 (SQL迁移 0037)

```sql
-- card-images桶: file_size_limit=5MB, allowed_mime_types
-- 上传策略: 仅本人目录 + MIME白名单
-- 删除策略: 仅本人 + service_role
```

### Phase 4: 前端页面修复 (修改)

```
index.html        → 引入risk-control.js + 上传验证
collection.html   → 引入risk-control.js + 上传验证
publish.html      → 引入risk-control.js + 上传验证
sell.html         → 引入risk-control.js (已有10MB限制,改为5MB)
scan-history.html → XSS修复 (escapeHtml)
```

### Phase 5: 密钥清理

```
scripts/fetch-tcgdex-prices.js → service_role改为环境变量
ai-scan index.ts/js            → API密钥改为仅Deno.env.get()
.env.local                     → 移除secret key,加入.gitignore
```

---

## 3. 涉及文件

| 文件 | 操作 | Phase |
|---|---|---|
| `js/risk-control.js` | 新建 | 1 |
| `supabase/functions/ai-scan/index.ts` | 修改 | 2 |
| `supabase/migrations/0037_image_upload_security.sql` | 新建 | 3 |
| `index.html` | 修改 | 4 |
| `collection.html` | 修改 | 4 |
| `publish.html` | 修改 | 4 |
| `sell.html` | 修改 | 4 |
| `scan-history.html` | 修改 | 4 |
| `scripts/fetch-tcgdex-prices.js` | 修改 | 5 |
| `.gitignore` | 修改 | 5 |

---

## 4. 数据库影响

| 变化 | 说明 |
|---|---|
| SQL迁移0037 | Storage桶配置更新 + MIME限制策略 |
| 无新表 | 利用现有 ai_scan_logs 防刷 |
| 无新RPC | Edge Function内直接验证JWT |

---

## 5. 风险评估

| 风险 | 等级 | 缓解措施 |
|---|---|---|
| ai-scan改认证后旧版客户端断线 | 中 | anon key仍可认证，仅拒绝完全匿名 |
| Storage策略变更影响已有图片 | 低 | 仅影响新上传，已有文件不变 |
| 图片压缩可能影响识卡精度 | 低 | 5MB内不压缩，超限才压缩到85% |
| risk-control.js引入增加页面体积 | 低 | ~2KB，PWA缓存 |

---

## 6. 回退方案

- Edge Function: 保留旧版index.ts备份，新版失败可回退
- Storage策略: SQL迁移可逆（DROP POLICY → 重建旧策略）
- risk-control.js: 前端引用可移除，回退到无验证状态

---

*等待王总确认后执行。*
