# DATABASE_RULES.md — 卡域 CardRealm 数据库规则

> **版本**: 1.0 | **更新**: 2026-07-08 | **适用**: 卡域APP全项目

---

## 1. 数据库概览

- **引擎**: PostgreSQL 15+ (Supabase托管)
- **项目**: `xybpcsmjjcnkjwfsuder`
- **域名**: `cardrealm.top`
- **访问**: 前端用 anon key + RLS；后端用 service_role（仅Edge Function）
- **Schema**: `public` (主业务), `extensions` (pgcrypto等), `auth` (Supabase内置)

---

## 2. 核心表结构

### 2.1 用户系统

| 表 | 用途 | 关键字段 |
|---|---|---|
| auth.users | Supabase内置用户 | id, email, phone |
| profiles | 用户资料+角色 | id, role(admin/merchant/user), merchant_name, merchant_badge |
| admins | 独立管理员系统(0033) | username, password_hash, session_token, token_expires_at, status |

### 2.2 卡牌系统

| 表 | 用途 | 关键字段 |
|---|---|---|
| user_collections | 用户卡牌收藏 | source, reserved_quantity, current_price |
| card_prices | 卡牌市价(旧) | current_price, previous_price, change_percent |
| card_market | 多源价格聚合(核心) | live/market/ai_price, final_price, price_source, price_locked, locked_price, source_type(platform/user) |

### 2.3 价格系统

| 表 | 用途 | 关键字段 |
|---|---|---|
| price_history | 每日价格快照 | daily_price, change_percent, series, rarity |
| price_change_events | 价格变动日志(0024) | old/new_price, change_percent, recorded_at |

### 2.4 资产系统

| 表 | 用途 | 关键字段 |
|---|---|---|
| portfolio_items | 用户持仓明细 | avg_buy_price, current_price, profit_loss |
| user_portfolio | 用户资产总览 | total_asset_value, total_cost, profit_loss |
| user_daily_snapshot | 每日资产快照 | total_asset, change_percent |

### 2.5 交易系统

| 表 | 用途 | 关键字段 |
|---|---|---|
| consignments | 交易挂单 | collection_id, quantity, status, is_platform_sale, sale_source, live_session_id |
| products | 商城商品 | category, stock, is_platform_product, seller_id |
| reservations | 预约购买 | status, source |

### 2.6 直播系统(0032)

| 表 | 用途 | 关键字段 |
|---|---|---|
| live_sessions | 直播场次 | host_id, platform, live_room_id, status, auto_list_after_live |
| live_sync_items | 直播商品同步 | live_session_id, consignment_id, asking_price |

### 2.7 平台发行系统(0033)

| 表 | 用途 | 关键字段 |
|---|---|---|
| platform_cards | 平台发行卡牌 | name, listing_price, stock_quantity, available_quantity(生成列), card_market_id, status |
| pre_orders | 预约/意向订单 | order_no, user_id, platform_card_id, reserved_price, total_amount, status, payment_status |
| platform_issue_logs | 平台操作日志 | admin_id, action, target_type, target_id, details |

### 2.8 AI识卡

| 表 | 用途 | 关键字段 |
|---|---|---|
| ai_scan_logs | 识卡记录+防刷 | user_id, image_hash, scan_result, daily_count |

---

## 3. 触发器链（核心，禁止修改计算顺序）

### 3.1 价格触发器链

```
card_prices INSERT/UPDATE
  → trg_card_prices_to_market
  → 更新 card_market.market_price

card_market BEFORE INSERT/UPDATE (全列)
  → trg_card_market_price
  → 计算 final_price (三级定价: live→market→ai→0)
  → 处理锁定逻辑 (price_locked → locked_price)
  → 计算 unlocked_price
  → CHECK约束验证

card_market final_price 变更
  → trg_market_to_portfolio
  → 更新 portfolio_items.current_price

card_market unlocked_price 变更
  → trg_log_price_changes
  → price_change_events (≥5%变动)

portfolio_items 变更
  → trg_portfolio_auto_refresh
  → 更新 user_portfolio + user_daily_snapshot
```

### 3.2 交易触发器

```
consignments 自营标记
  → trg_mark_platform_sale
  → is_platform_sale = true (admin商家上架时)
```

### 3.3 市场状态触发器(0031)

```
card_market 写入
  → trg_update_market_state
  → market_state 表自动更新
```

---

## 4. RPC 规范

### 4.1 命名规则

- 动词前缀: `create_`, `update_`, `cancel_`, `get_`, `admin_`
- 返回类型: 明确 `RETURNS TABLE` 或 `RETURNS JSONB`
- 所有参数必须有 `DEFAULT` 值（从首个可选参数起）

### 4.2 安全规则

- 所有 RPC 必须 `SET search_path = ''` + `SECURITY DEFINER`
- pgcrypto 函数用 `extensions.crypt()` / `extensions.gen_salt()` / `extensions.gen_random_uuid()`
- 不在 RPC 中暴露 service_role 权限给前端

### 4.3 参数冲突规则（经验总结）

| 问题 | 原因 | 解决方案 |
|---|---|---|
| RETURNS TABLE 列名与表列名冲突 | RETURNING/UPDATE引用歧义 | 添加 `#variable_conflict use_column` 或用局部变量 v_xxx |
| ELSE status 歧义 | `SET search_path = ''` 下 ELSE status 指向 RETURN TABLE 列 | 用 `ELSE table_name.status` 限定 |
| 42P13 参数默认值顺序 | 有默认值参数后所有参数也必须有默认值 | 全部RPC参数加DEFAULT |
| CREATE OR REPLACE 改参数名 | 不允许修改参数名 | 先 `DROP FUNCTION IF EXISTS` 再重建 |

---

## 5. 核心RPC清单

### 5.1 识卡系统

| RPC | 用途 |
|---|---|
| `complete_card_entry` | 统一入库(17参数,原子操作) |

### 5.2 交易系统

| RPC | 用途 |
|---|---|
| `create_consignment_from_collection` | 上架(冻结库存) |
| `purchase_consignment` | 购买(FOR UPDATE行锁,原子交易) |
| `cancel_consignment` | 取消(释放库存) |
| `sync_card_to_live` | 直播同步 |

### 5.3 商家系统

| RPC | 用途 |
|---|---|
| `admin_verify_merchant` | 商家认证 |
| `admin_revoke_merchant` | 取消商家 |

### 5.4 价格系统

| RPC | 用途 |
|---|---|
| `upsert_card_market` | 更新card_market(支持清除参数) |
| `lock_card_price` | 锁定价格 |
| `unlock_card_price` | 解锁价格 |
| `check_and_auto_lock_prices` | 检查自动锁定 |
| `verify_price_truth_rule` | 验证价格真值 |
| `take_daily_price_snapshot` | 每日快照 |
| `get_card_price_trend` | 价格趋势(7d/30d) |
| `get_market_volatility_ranking` | 波动率排名 |
| `get_trending_cards` | 热门卡牌 |
| `get_market_heat_index` | 市场热度 |

### 5.5 平台发行系统

| RPC | 用途 |
|---|---|
| `admin_publish_card` | 平台发行卡牌 |
| `create_pre_order` | 创建预约(锁定价格) |
| `cancel_pre_order` | 取消预约(释放库存) |
| `admin_confirm_pre_order` | 确认支付 |

### 5.6 管理员系统

| RPC | 用途 |
|---|---|
| `admin_login` | 管理员登录 |
| `admin_logout` | 管理员登出 |

---

## 6. CHECK 约束

| 约束名 | 表 | 规则 |
|---|---|---|
| `chk_price_truth_rule` | card_market | final_price = 首个非零(live/market/ai)或0 |
| `chk_price_source_values` | card_market | price_source IN ('live','market','ai_estimate','none') |
| platform_issue_logs action | platform_issue_logs | action IN (已定义列表) — 新操作需扩展 |
| platform_issue_logs target_type | platform_issue_logs | target_type IN (已定义列表) — 新目标需扩展 |

**重要**: 添加新的管理操作时，必须先扩展 platform_issue_logs 的 CHECK 约束，否则会触发 23514 违反。

---

## 7. 视图

| 视图 | 用途 |
|---|---|
| `market_list_with_seller` | 市场列表+商家信息(自营优先排序, seller_weight) |
| `platform_store_list` | 平台商城列表(仅source_type=platform) |

---

## 8. 迁移管理

### 8.1 迁移文件规范

- 格式: `{4位编号}_{英文描述}.sql`
- 位置: `supabase/migrations/`
- 编号必须递增，当前最大: 0036
- 下一个可用: 0037
- 跳号允许，不允许回退

### 8.2 执行方式

- SQL迁移: Python urllib + Management API
- 必须加 `User-Agent` 头绕过 Cloudflare
- Edge Function: `npx supabase functions deploy` + PAT

### 8.3 迁移索引（已执行）

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
| 0031 | market_state自动更新触发器(代码已提交，SQL未执行) | ⚠️ |
| 0032 | 商家角色+自营标识+直播同步 | ✅ |
| 0033 | 平台方商品发行系统 | ✅ |
| 0034 | 分层卡牌经济系统(三层市场) | ✅ |
| 0036 | 生产RLS安全修复 | ✅ |

---

## 9. 禁止操作

| # | 禁止 | 原因 |
|---|---|---|
| 1 | 修改触发器链计算顺序 | 价格体系核心 |
| 2 | 删除 CHECK 约束 | 数据完整性保障 |
| 3 | 直接 ALTER 核心表列类型 | 可能破坏触发器 |
| 4 | 在 RPC 中使用裸 status 引用 | 搜索路径歧义 |
| 5 | CREATE OR REPLACE 修改参数名 | PostgreSQL不支持 |
| 6 | ON CONFLICT 匹配 NULL 值 | 用部分唯一索引 WHERE col IS NOT NULL |
| 7 | 窗口函数嵌套在聚合函数中 | 拆分多步CTE |

---

*本文件定义数据库操作边界，数据库变更需王总审批。*
