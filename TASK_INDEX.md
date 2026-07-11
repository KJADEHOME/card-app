# TASK_INDEX.md — 卡域 CardRealm 任务总索引

> **版本**: 1.0 | **更新**: 2026-07-08 | **项目根**: `D:/codex/cardrealm/card-app/`
> **当前阶段**: Production Beta Preparation

---

## 规范文件（必读）

每次执行任务前必须先读取：

| 文件 | 位置 |
|---|---|
| PROJECT_RULES.md | `D:/codex/cardrealm/card-app/PROJECT_RULES.md` |
| ARCHITECTURE.md | `D:/codex/cardrealm/card-app/ARCHITECTURE.md` |
| DATABASE_RULES.md | `D:/codex/cardrealm/card-app/DATABASE_RULES.md` |
| SECURITY_RULES.md | `D:/codex/cardrealm/card-app/SECURITY_RULES.md` |

---

## ✅ Completed

### AI

| ID | 任务 | 文档 |
|---|---|---|
| AI-001 | AI识卡基础流程 | — |
| AI-002 | Gemini接入 | — |
| AI-003 | AI Fallback机制 | — |

### Market

| ID | 任务 | 文档 |
|---|---|---|
| MARKET-001 | Price Truth Rule (0023锁死) | — |
| MARKET-002 | Mark Price System (三级定价) | — |
| MARKET-003 | Dynamic Weight Pricing | — |

### Asset

| ID | 任务 | 文档 |
|---|---|---|
| ASSET-001 | Portfolio System (触发器链) | — |

### Security

| ID | 任务 | 文档 |
|---|---|---|
| SEC-000 | Security Audit (0036 RLS修复) | — |

---

## ✅ Completed (Updated)

### SECURITY

| ID | 任务 | 状态 | 文档 |
|---|---|---|---|
| SEC-004 | Image Upload Security | **✅ Completed** | `TASKS/SECURITY/SEC-004_image_upload_security.md` |

---

## 📋 Planned

### PAYMENT

| ID | 任务 | 状态 | 文档 |
|---|---|---|---|
| PAY-001 | Payment Architecture | Planned | — |
| PAY-002 | WeChat Pay | Planned | — |
| PAY-003 | Alipay Sandbox | Planned | — |
| PAY-004 | Payment Callback | Planned | — |

### SHOP

| ID | 任务 | 状态 | 文档 |
|---|---|---|---|
| SHOP-001 | Platform Product | Planned | — |
| SHOP-002 | Pre-sale System | Planned | — |
| SHOP-003 | Inventory | Planned | — |

### SOCIAL

| ID | 任务 | 状态 | 文档 |
|---|---|---|---|
| SOCIAL-001 | Community | Planned | — |
| SOCIAL-002 | Card Sharing | Planned | — |
| SOCIAL-003 | Ranking | Planned | — |

---

## 数据库迁移索引

| 编号 | 内容 | 状态 |
|---|---|---|
| 0010 | ai_scan_logs + 防刷 | ✅ |
| 0012 | 交易+库存系统 | ✅ |
| 0014 | 商城系统 | ✅ |
| 0015 | 增长+留存系统 | ✅ |
| 0016 | 预约购买系统 | ✅ |
| 0020 | Fallback统一入库 | ✅ |
| 0021 | 资产市场化(card_market/portfolio) | ✅ |
| 0022 | 市场趋势(daily_price/volatility) | ✅ |
| 0023 | 锁死价格真值规则(三层防护) | ✅ |
| 0024 | 价格锁定机制(Price Lock) | ✅ |
| 0029 | 市场数据注入(55张卡) | ✅ |
| 0030 | 修复 compute_card_market_price 触发器 | ✅ |
| 0031 | market_state自动更新触发器 | ⚠️ SQL未执行 |
| 0032 | 商家角色+自营标识+直播同步 | ✅ |
| 0033 | 平台方商品发行系统 | ✅ |
| 0034 | 分层卡牌经济系统(三层市场) | ✅ |
| 0036 | 生产RLS安全修复 | ✅ |
| 0037 | 图片上传安全(SEC-004) | ✅ Executed |

**下一个可用迁移编号**: 0037

---

## 执行规则

1. 读取4个规范文件
2. 找到任务文档 (`TASKS/{模块}/{ID}_*.md`)
3. 分析 → 输出修改计划 → 等确认 → 执行 → 完成报告
4. 更新本文件的任务状态和迁移索引

---

*本文件为项目任务导航中心，每次进入项目时首先读取此文件。*
