# PROJECT_RULES.md — 卡域 CardRealm 总开发规范

> **版本**: 1.0 | **更新**: 2026-07-08 | **适用**: 卡域APP全项目

---

## 1. 项目定位

**卡域 CardRealm** — TCG卡牌资产管理 + 交易生态平台  
支持：游戏王 / 宝可梦 / 万智牌 / 体育卡等

核心价值链：`AI识卡 → 资产估值 → 市场交易 → 社区生态`

---

## 2. 技术栈（锁定，禁止随意更换）

| 层 | 技术 | 说明 |
|---|---|---|
| 前端 | PWA (HTML/CSS/JS) | 无框架，原生 Web，单页多入口 |
| 后端 | Supabase | Auth + DB + Storage + Edge Functions |
| 数据库 | PostgreSQL 15+ | PL/pgSQL RPC + 触发器链 |
| AI | Gemini 2.5 Flash | ai-scan Edge Function |
| 部署 | Supabase Edge Functions + Cloudflare Pages | 全球 CDN |
| PWA | Service Worker + manifest.json | 离线优先 |

**禁止引入**: React/Vue/Angular/Next.js 等前端框架；Python/FastAPI 等后端框架

---

## 3. 开发流程（强制执行）

### 3.1 修改流程

```
分析需求 → 输出修改计划 → 等确认 → 执行 → 测试 → 完成报告
```

### 3.2 修改计划必须包含

- 修改目的
- 涉及文件清单
- 数据库影响（新表/新列/新RPC/新触发器）
- 风险评估
- 回退方案

### 3.3 完成报告格式

```
==========
TASK COMPLETE

任务编号：xxx

修改文件：
  - path/to/file1
  - path/to/file2

数据库变化：
  - 新增表/列/RPC/触发器

测试结果：
  - ✅ / ❌ 具体结果

影响范围：
  - 模块A / 模块B

剩余风险：
  - xxx

下一步建议：
  - xxx
==========
```

---

## 4. 绝对禁止操作

| # | 禁止 | 原因 |
|---|---|---|
| 1 | 随意重构架构 | 现有架构经过多轮验证，改动需审批 |
| 2 | 删除已有功能 | 用户已在使用，删除=断线 |
| 3 | 修改核心业务逻辑（价格/交易/库存） | 资金安全红线 |
| 4 | 引入未经确认的新技术/新依赖 | 增加不可控风险 |
| 5 | 在前端硬编码 API 密钥 | 安全红线 |
| 6 | 修改 Supabase service_role 在前端使用 | 安全红线 |
| 7 | 修改触发器链中的计算顺序 | 价格体系核心 |
| 8 | 跳过迁移编号规则 | SQL迁移必须编号递增 |

---

## 5. 文件命名规范

| 类型 | 格式 | 示例 |
|---|---|---|
| HTML页面 | `{功能}.html` | `marketplace.html` |
| 管理后台 | `admin-{模块}.html` | `admin-orders.html` |
| JS模块 | `js/{模块}.js` 或 `js/{功能}-{子模块}.js` | `js/auth.js` |
| SQL迁移 | `supabase/migrations/{编号}_{描述}.sql` | `0033_platform_cards.sql` |
| Edge Function | `supabase/functions/{名称}/index.ts` | `ai-scan/index.ts` |
| 服务器脚本 | `server/{名称}.py` 或 `server/{名称}.js` | `server/api.js` |
| 任务文档 | `TASKS/{模块}/{编号}_{描述}.md` | `TASKS/PAYMENT/001_alipay_sandbox.md` |

---

## 6. 迁移编号规则

- 格式：4位数字递增 + `_` + 英文描述
- 跳号允许（0035已跳过），但不允许回退
- 当前最大编号：0036
- 下一个可用编号：0037
- 每次执行前必须记录到 MEMORY.md 的迁移索引

---

## 7. Git 规范

- 分支：master（主分支，直接推送）
- GitHub：`KJADEHOME/card-app`
- 提交信息格式：`[模块] 简要描述`
- 部署文件（deploy_payload.json 等）不含硬编码密钥
- .gitignore 必须排除：node_modules, .env, deploy_payload.json

---

## 8. 依赖规范

- `package.json` 仅含开发辅助工具（gen_report.js 等）
- 不引入生产运行时依赖
- npm 包仅装在 `node_modules`，不全局安装
- Edge Function 依赖由 Supabase 管理，不额外引入

---

## 9. 测试规范

- 功能测试：手动浏览器验证（PWA特性需真机）
- 数据库测试：RPC 调用验证 + 触发器链验证
- 安全测试：RLS策略验证 + 权限边界测试
- AI测试：ai-scan Edge Function 请求/响应验证
- 所有测试结果记录在完成报告中

---

## 10. 项目关键凭证管理

| 凭证 | 存放位置 | 前端可见 |
|---|---|---|
| Supabase anon key | 前端 JS | ✅（公开安全） |
| Supabase service_role | 仅 Edge Function / SQL | ❌ 绝不前端 |
| Supabase PAT | deploy脚本环境变量 | ❌ |
| Gemini API Key | Edge Function Secrets | ❌ |
| 管理员密码 | admins 表 (pgcrypto哈希) | ❌ |

---

*本文件为项目最高规范，所有开发行为必须遵守。修改本文件需王总确认。*
