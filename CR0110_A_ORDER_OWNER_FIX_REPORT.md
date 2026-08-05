# CR-0110-A · create_sealed_product_order() Owner-Check 修复报告

| 项 | 值 |
|----|----|
| 跟踪问题 | SF-1 (HIGH) — 源自 CR0107 04F-U smoke test |
| 项目 | `D:\codex\cardrealm\card-app` (branch `release-beta-preparation`) |
| 修复函数 | `public.create_sealed_product_order()` |
| 修改方式 | 新增迁移（**不改动已上线的 0034 迁移**）|
| 新增文件 | `supabase/migrations/20260805170000_create_sealed_product_order_owner_check.sql` |
| 错误码 | `42501` (insufficient_privilege，与 RLS 违规一致) |
| 状态 | ✅ 修复完成，**WAITING CEO REVIEW**（未 db push / 未 git push）|

---

## 1. 背景与问题 (SF-1)

CR0107 04F-U 冒烟测试 TC-3.1 复现了一个安全缺口：

- `create_sealed_product_order(p_user_id, p_product_id, ...)` 为 `SECURITY DEFINER`，内部**直接使用传入的 `p_user_id` 建单**，从未校验调用者身份。
- 实测：以 **用户 A 的 JWT** 调用，但传入 `p_user_id = 用户 B`，函数成功为 B 创建了订单（订单 `user_id = B`）。
- 影响：任意已登录用户可替他人下单（如以他人身份下单、占用他人配额、或制造归属混乱）。

## 2. 修复内容

在 `BEGIN` 之后、任何业务逻辑之前，**fail-fast** 插入 owner-check：

```sql
BEGIN
  -- [CR-0110-A / SF-1] owner-check: 调用者只能为自己下单
  IF p_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Cannot create an order on behalf of another user'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_product_rec FROM public.sealed_products WHERE id = p_product_id;
  ...
```

### 保留项（确认未改动）
- 原订单创建逻辑（`INSERT INTO sealed_product_orders`、`order_no` 生成）
- 库存锁定（`UPDATE sealed_products SET reserved_quantity = reserved_quantity + p_quantity`）
- preorder 逻辑（`is_pre_order` 时间窗校验）
- payment 状态（`status='pending'`, `payment_status='unpaid'`）

## 3. 关键设计决策（请 CEO 审阅）

### 3.1 使用 `!=` 而非 `IS DISTINCT FROM`
- 客户端持**本人 JWT** 调用：`auth.uid()` = 本人 id，`p_user_id` = 本人 id → `!=` 为 FALSE → 放行 ✅
- 客户端伪造他人 `p_user_id`：`auth.uid()` = 本人 id，`p_user_id` = 他人 id → `!=` 为 TRUE → RAISE 42501 ✅
- **以 `service_role` key 调用**（Edge Function/后台）：`auth.uid()` 为 **NULL**，`p_user_id != NULL` 求值 **NULL**（非 TRUE）→ **不触发**，保留合法后台/管理员调用 ✅
- 若误用 `IS DISTINCT FROM`，则 `p_user_id IS DISTINCT FROM NULL` 在 service_role 场景会返回 TRUE → 误杀后台调用。故**必须用普通 `!=`**。

### 3.2 `auth.uid()` 在 `SECURITY DEFINER SET search_path=''` 下的可用性
- `auth.uid()` 读取请求级 GUC `request.jwt.claims`，该 GUC **不被 `SECURITY DEFINER` 清空**，仍反映调用者 JWT 的 `sub`。
- 以 `auth.` 完全限定调用，在 `search_path=''` 下可正常解析。
- 因此 owner-check 在客户端 JWT 调用路径生效，符合预期。

### 3.3 调用方影响分析
- 仓库内**未发现** `create_sealed_product_order` 的客户端/Edge Function 调用点（grep `*.{js,ts,html}` 无命中）。该函数作为 RPC 由客户端（authenticated key）带 `p_user_id` 调用，正是 SF-1 描述的滥用路径。
- 上线后客户端**必须**传 `p_user_id = 当前登录用户 id`，否则合法调用也会被 42501 拒绝（即为预期行为）。
- `service_role` 调用方（若有后台/Edge Function 经此建单）**不受影响**（见 3.1）。

## 4. 静态验证结果

对原函数（迁移 `2024010100000034_tiered_market_system_authoritative.sql`）与修复后函数做整函数 `diff`（去除注释行、并去 owner-check 块后比较）：

```
--- ORIG
+++ NEW
@@ -49,4 +50,4 @@
 END;
 $func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-COMMENT ON FUNCTION create_sealed_product_order() IS '...锁定价格, 冻结库存';
+COMMENT ON FUNCTION create_sealed_product_order() IS '...锁定价格, 冻结库存 [CR-0110-A] 强制 p_user_id = auth.uid() (SF-1 修复)';
```

- ✅ 函数体**逐行一致**，仅新增 owner-check 块（4 行）与 COMMENT 文案更新。
- ✅ 订单逻辑 / 库存锁定 / preorder / payment 状态字段**零改动**。
- ✅ PL/pgSQL 语法：`RAISE EXCEPTION ... USING ERRCODE = '42501'` 合法；`auth.uid()` 完全限定可解析。

## 5. 运行时验证（部署后执行）

> 本任务**禁止 `db push` / `git push`**，故运行时验证需在 CEO 批准并部署后执行（建议在独立验证任务或 Beta 上跑）。下方为即用 SQL（沿用 04F-U 的 RLS 模拟手法）。

### 前置
- 两个测试账号：`UA = <user_a_uuid>`、`UB = <user_b_uuid>`（仅 owner-check 验证，不落真实业务数据；单测订单需事后清理）。
- 一个真实 `sealed_products.id = <product_uuid>`（状态 active，`stock_quantity` 充足）。

### TC-A.1 用户 A 创建自己的订单 → 期望成功
```sql
SET ROLE authenticated;
SET request.jwt.claims='{"sub":"<UA_UUID>","role":"authenticated"}';
SELECT success, order_id, total_amount, message
FROM create_sealed_product_order('<UA_UUID>', '<PRODUCT_UUID>', 1);
-- 期望: success = true
```

### TC-A.2 用户 A 创建用户 B 的订单 → 期望 42501
```sql
SET ROLE authenticated;
SET request.jwt.claims='{"sub":"<UA_UUID>","role":"authenticated"}';
SELECT create_sealed_product_order('<UB_UUID>', '<PRODUCT_UUID>', 1);
-- 期望: ERROR  42501  insufficient_privilege
--        Cannot create an order on behalf of another user
```

### 清理（仅 TC-A.1 产生的测试订单）
```sql
DELETE FROM sealed_product_orders WHERE sealed_product_id = '<PRODUCT_UUID>'
  AND user_id = '<UA_UUID>' AND status='pending' AND payment_status='unpaid';
-- 同步回退 reserved_quantity（如需要）：
UPDATE sealed_products SET reserved_quantity = reserved_quantity - 1 WHERE id = '<PRODUCT_UUID>';
```

## 6. 守禁项确认

| 禁止项 | 状态 |
|--------|------|
| `supabase db push` | ✅ 未执行 |
| `git push` | ✅ 未执行 |
| 改动已上线迁移 0034 | ✅ 未改动（新增独立迁移）|
| 直接在 Beta 应用 DDL | ✅ 未执行（仅静态 diff 验证）|
| 触碰生产/业务数据 | ✅ 未触碰 |

## 7. 后续步骤（建议）

1. **CEO 审阅**本修复与新迁移文件。
2. 审阅通过后，由专人执行 `npx supabase db push` 部署（将 69 → 69 Local/Remote）。
3. 部署后在 Beta 跑第 5 节 TC-A.1 / TC-A.2 验证，确认 42501 生效且自下单正常。
4. （可选）回归：确认任何现有客户端调用均传 `p_user_id = 登录用户 id`。

---
*关联：CR0107 04F-U（SF-1 复现）、CR-0110 系列。函数 authoritative 定义位于 `2024010100000034_tiered_market_system_authoritative.sql` Part 14。*
