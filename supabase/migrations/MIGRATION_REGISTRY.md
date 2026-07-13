# CardRealm 迁移登记 (MIGRATION_REGISTRY)

> 最后更新: 2026-07-13
> 维护者: 冰沙 (AI Agent)

## 迁移编号规范

- 编号格式: `NNNN_descriptive_name.sql`
- 递增编号，不跳号，不复用
- 最大已占用编号: **0039**
- 下一个可用编号: **0040**
- SH-003C Phase 3 占用: 0040-0043 (Group A-C + D停用)
- SH-006B 重新编号后占用: 0044-0046 (原0039-0041需调整，因为0039已被Phase2占用)

## 登记表

| 编号 | 文件名 | 所属任务 | 状态 | Git commit | 线上执行日期 | 说明 |
|------|--------|----------|------|------------|-------------|------|
| 0001 | 0001_add_market_listings_columns.sql | 基础系统 | deployed | - | - | 市场列表 |
| 0002 | 0002_add_feedback_table.sql | 基础系统 | deployed | - | - | 反馈表 |
| 0003 | 0003_add_dashboard_tables.sql | 基础系统 | deployed | - | - | 仪表盘 |
| 0004 | 0004_add_collection_tables.sql | 基础系统 | deployed | - | - | 收藏表 |
| 0005 | 0005_add_community_tables.sql | 基础系统 | deployed | - | - | 社区表 |
| 0006 | 0006_add_marketplace_tables.sql | 基础系统 | deployed | - | - | 交易市场 |
| 0007 | 0007_add_points_system.sql | 基础系统 | deployed | - | - | 积分系统 |
| 0008 | 0008_add_missing_features.sql | 基础系统 | deployed | - | - | 补充功能 |
| 0009 | 0009_add_recharge_status.sql | 基础系统 | deployed | - | - | 充值状态 + approve/reject RPC |
| 0010 | 0010_add_ai_scan_logs.sql | AI | deployed | - | - | AI扫描日志 |
| 0011 | 0011_market_pricing_system.sql | 价格系统 | deployed | - | - | 定价系统 |
| 0012 | 0012_trading_inventory_system.sql | 交易系统 | deployed | - | - | 交易库存 |
| 0013 | 0013_risk_control_system.sql | 安全 | deployed | - | - | 风控系统 |
| 0014 | 0014_shop_system.sql | 商城 | deployed | - | - | 商城系统 |
| 0015 | 0015_growth_retention.sql | 增长 | deployed | - | - | 增长留存 |
| 0016 | 0016_reservation_system.sql | 商城 | deployed | - | - | 预约系统 |
| 0017 | 0017_ai_scan_fault_tolerance.sql | AI | deployed | - | - | AI容错 |
| 0018 | 0018_order_status_machine.sql | 交易系统 | deployed | - | - | 订单状态机 |
| 0019 | 0019_add_user_management_fields.sql | 管理员 | deployed | - | - | 用户管理 + admin_disable/enable |
| 0020 | 0020_fallback_card_entry.sql | AI | deployed | - | - | 卡片录入回退 |
| 0021 | 0021_asset_marketization.sql | 价格系统 | deployed | - | - | 资产市场化 |
| 0022 | 0022_price_history_market_trends.sql | 价格系统 | deployed | - | - | 价格历史/趋势 |
| 0023 | 0023_lock_price_truth_rule.sql | 价格系统 | deployed | - | - | 三级定价规则 |
| 0024 | 0024_price_lock_mechanism.sql | 价格系统 | deployed | - | - | 价格锁定 |
| 0025 | 0025_dynamic_weight_pricing_engine.sql | 价格系统 | deployed | - | - | 动态权重定价 |
| 0026 | 0026_portfolio_use_mark_price.sql | 价格系统 | deployed | - | - | 持仓用mark_price |
| 0027 | 0027_price_explanation_system.sql | 价格系统 | deployed | - | - | 价格解释 |
| 0028 | 0028_fix_price_explanation_format.sql | 价格系统 | deployed | - | - | 修复价格解释格式 |
| 0029 | 0029_market_data_seeding.sql | 价格系统 | deployed | - | - | 市场数据种子 |
| 0030 | 0030_fix_compute_card_market_price.sql | 价格系统 | deployed | - | - | 修复定价计算 |
| 0031 | 0031_fix_market_state_trigger.sql | 价格系统 | deployed | - | - | 修复市场状态触发器 |
| 0032 | 0032_merchant_role_platform_stock_live_sync.sql | 商家+直播 | deployed | - | - | 商家角色+直播同步+admin_verify/revoke/bulk_list |
| 0033 | 0033_platform_issued_inventory_system.sql | 平台发行 | deployed | - | - | 平台发行系统+admin_login/token/publish/update/confirm |
| 0034a | 0034_fix_batch1.sql | 分层经济 | deployed | - | - | 修复Batch1 |
| 0034b | 0034_fix_batch2.sql | 分层经济 | deployed | - | - | 修复Batch2 |
| 0034c | 0034_fix_public_prefix.sql | 分层经济 | deployed | - | - | 修复函数前缀 |
| 0034d | 0034_tiered_market_system.sql | 分层经济 | deployed | - | - | 分层卡牌经济+sealed/merchandise RPC |
| 0035 | 0035_payment_escrow_system.sql | 支付 | deployed | - | - | 支付托管系统 |
| 0036 | 0036_production_rls_security_fixes.sql | 安全(SH-002) | deployed | - | 2026-07-11 | 生产RLS安全修复 |
| 0037 | 0037_image_upload_security.sql | 安全(SEC-004) | **local** | - | - | 图片上传安全 (代码已完成, SQL未线上执行) |
| 0038 | 0038_admin_auth_unification_phase1.sql | 安全(SH-003C P1) | deployed | f7aff8a | 2026-07-13 | 管理员认证统一Phase1 (require_admin/log_admin_action/protect_trigger等) |
| 0039 | 0039_admin_orders_rpc.sql | 安全(SH-003C P2) | deployed | 7aab7bb | 2026-07-13 | Admin Orders RPC (cancel/refund/dispute + 5列) |

## 规划中 (未创建文件)

| 编号 | 文件名 | 所属任务 | 状态 | 说明 |
|------|--------|----------|------|------|
| 0040 | 0040_admin_rpc_group_a.sql | SH-003C P3-A | **local** | Group A: Supabase Auth登录/发布RPC + 旧token认证停用 |
| 0041 | 0041_admin_rpc_group_b.sql | SH-003C P3-B | **local** | Group B: 充值审批RPC去除前端admin UID |
| 0042 | 0042_admin_rpc_group_c.sql | SH-003C P3-C | **local** | Group C: 用户/商户管理统一require_admin认证 |
| 0043 | 0043_admin_rpc_group_d_disable.sql | SH-003C P3-D | **local** | Group D: 8个无调用旧RPC撤销浏览器执行权限 |
| 0044 | 0044_financial_fk_safety.sql | SH-006B P0 | **planned** | 金融FK安全 (原0039号,因冲突调整为0044) |
| 0045 | 0045_profiles_auth_fk.sql | SH-006B P1 | **planned** | profiles auth FK (原0040号调整为0045) |
| 0046 | 0046_cards_master_phase1.sql | SH-006B P2 | **planned** | cards主表Phase1 (原0041号调整为0046) |

## 辅助文件 (不计入编号)

| 文件 | 说明 |
|------|------|
| check_0035_critical.sql | 0035前置检查 |
| check_0035_status.sql | 0035状态检查 |
| cleanup_test_payment_data.sql | 测试数据清理 |
| fix_0035_field_mismatch.sql | 0035字段修复 |
| test_0038_sh003c_phase1.sql | 0038测试脚本 |

## 编号冲突记录

- **0039**: 原SH-006B计划使用 (金融FK安全), 后被SH-003C P2实际占用 (admin_orders_rpc). SH-006B编号调整为 0044-0046.
