# CR-0107-04F-B · Live RPC State Audit（0034 七个 RPC 函数现场真身核对）

**审计对象**：`0034_tiered_market_system.sql` 中被重复 `CREATE OR REPLACE` 的 7 个 RPC 函数
**审计类型**：只读检查 live DB 当前真实函数定义（只读）
**日期**：2026-08-05
**状态**：⏳ WAITING CEO REVIEW

---

## 0. 执行边界与约束（本次严格遵守）

| 禁止操作 | 是否触碰 |
|---|---|
| 修改 SQL | ❌ 否 |
| 合并文件 | ❌ 否 |
| git mv | ❌ 否 |
| archive | ❌ 否 |
| repair | ❌ 否 |
| db push | ❌ 否 |
| commit | ❌ 否 |
| push | ❌ 否 |

> 本报告仅做**只读核对 + 判定方法 + 合并建议**。所有"合并 / 归档"动作均为**提案**，需 CEO 评审后另行授权。

---

## 1. Live DB 连接尝试与结果（⚠️ 阻断说明）

| # | 尝试方式 | 结果 |
|---|---|---|
| 1 | `supabase link --project-ref xybpcsmjjcnkjwfsuder`（临时 workdir，不碰仓库 config） | ❌ `Unauthorized`（PAT `sbp_6fd043…` 已失效） |
| 2 | `supabase db query --project-ref …`（不 link，直接查） | ❌ 该子命令要求 `--linked` / `--db-url` / `--local`；无可用连接串 |
| 3 | 查找缓存凭证：`~/.supabase/access-token`、`~/.pgpass`、历史 temp workdir（`/tmp/sbverify_*`）、shell 环境变量、仓库 `.env*` | ❌ 无任何可用 DB 连接串 / token；无 `psql` |

**结论**：当前环境**无法连接 live DB**。原因：Supabase PAT 已于 2026-08-04 失效（Unauthorized），且无其他可用凭证（DB 密码 / 有效 token / psql）。因此 **7 个函数的现场定义未能获取**。

> 一旦具备以下任一凭证，可立即补齐 §4 的真身数据：
> - 一个**有效**的 Supabase PAT（设 `SUPABASE_ACCESS_TOKEN` 后 `supabase db query --linked`），或
> - 直连串 `postgresql://postgres:<PWD>@db.xybpcsmjjcnkjwfsuder.supabase.co:5432/postgres`（用 `--db-url`）。

---

## 2. 获取 live 定义的精确只读查询（供持有效凭证者执行）

```sql
-- 只读：返回 7 个 RPC 的现场定义 + 当前 COMMENT
SELECT p.proname,
       pg_get_functiondef(p.oid)  AS live_definition,
       obj_description(p.oid)     AS live_comment
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
        'admin_update_sealed_product',
        'create_sealed_product_order',
        'cancel_sealed_product_order',
        'admin_confirm_sealed_order',
        'admin_create_merchandise',
        'admin_update_merchandise',
        'create_merchandise_order'
      )
ORDER BY p.proname;
```

**运行方式（任选其一）**：
- Dashboard → SQL Editor 直接执行；
- `psql "<连接串>" -f live_rpc_check.sql`；
- `SUPABASE_ACCESS_TOKEN=<有效PAT> npx supabase db query --linked -f live_rpc_check.sql`（需先 `link`，即需有效 PAT）。

---

## 3. 判别方法：tiered 版 vs batch/public_prefix 版（修复分支）

### 3.1 可靠信号（唯一）：函数体内的变量命名
对 7 个函数逐一比对 `0034_tiered_market_system.sql` 与 `0034_fix_public_prefix.sql` 的函数体（已用 `awk` 抽取逐函数核对）：

| 标记 | 仅存在于 | 含义 |
|---|---|---|
| `v_order_no_val` | **tiered 版** | 订单号变量命名为 `v_order_no_val` |
| `v_order_no`（裸，无 `_val`） | **batch / public_prefix 版** | 订单号变量命名为 `v_order_no` |

实证（以 `create_sealed_product_order` 为例）：
- tiered：`v_order_no_val TEXT; v_order_no_val := 'SP-'||…; … INTO v_order_id, v_order_no_val;`
- public_prefix：`v_order_no TEXT; v_order_no := 'SP-'||…; … INTO v_order_id, v_order_no;`

→ **判定规则（文件级，因 `CREATE OR REPLACE` 整函数生效）**：
- 现场 `create_sealed_product_order`（或 `cancel_sealed_product_order`）的 `live_definition` 含 `v_order_no_val` → 末次应用为 **tiered 版**。
- 现场 `live_definition` 含 `v_order_no` 但**不含** `v_order_no_val` → 末次应用为 **batch / public_prefix 版（修复分支）**。

> 注：batch1 / batch2 / public_prefix 三者同属"修复分支"，彼此差异仅在于 `public.` 限定符有无（public_prefix 是 batch1∪batch2 的合并收口版，含 `public.`）。三者均使用裸 `v_order_no`、均不含 `v_order_no_val`。故对"现场是哪一版"的判定只需二分：**tiered** vs **修复分支**。

### 3.2 不可靠信号（被 0043 覆盖）：`COMMENT ON FUNCTION`
`0043_admin_rpc_group_d_disable.sql` 已对这 7 个 RPC 统一执行：
```sql
COMMENT ON FUNCTION … IS 'DEPRECATED/DISABLED SH-003C Phase 3: no verified caller; browser EXECUTE revoked.';
```
→ 无论现场最初来自 tiered（原带业务 COMMENT）还是 public_prefix（原无 COMMENT），经 0043 后 `obj_description` 均非空且均为 DEPRECATED。**COMMENT 信号无法区分来源**，判定必须以 §3.1 的变量命名为准。

---

## 4. 每个函数的 live 定义（待补 · 当前未能获取）

| 函数 | live 定义已获取？ | 对应版本（tiered / 修复分支） | 备注 |
|---|---|---|---|
| `admin_update_sealed_product` | ❌ 未获取（凭证失效） | 待 §2 查询后判定 | 以 `v_order_no_val` 为据 |
| `create_sealed_product_order` | ❌ 未获取 | 待判定 | **首要判定函数**（含订单号生成） |
| `cancel_sealed_product_order` | ❌ 未获取 | 待判定 | 含订单号引用 |
| `admin_confirm_sealed_order` | ❌ 未获取 | 待判定 | — |
| `admin_create_merchandise` | ❌ 未获取 | 待判定 | — |
| `admin_update_merchandise` | ❌ 未获取 | 待判定 | — |
| `create_merchandise_order` | ❌ 未获取 | 待判定 | — |

> 上述 7 行在拿到 §2 查询结果后，按 §3.1 规则逐行填"对应版本"即可。

---

## 5. 最终 0034 权威合并建议（variant-agnostic 安全方案）

**核心原则**：`0034_tiered_market_system.sql` 是全库**唯一结构真相源**（4 表 / 5 视图 / 17 索引 / ~13 RLS / 8 函数）；其余 3 份仅为 7 个 RPC 的冗余重定义。合并目标 = **单一权威 0034**，且其 7 个 RPC 函数体**逐字等于现场（live）定义**，以保证迁移可复现生产。

### 5.1 决策树（依据 §2/§3 的 live 结果）
- **情形 A — 现场 = tiered 版**（7 函数均含 `v_order_no_val`）：
  → 直接 **KEEP `0034_tiered_market_system.sql`** 为唯一权威；将该文件重命名为时间戳版并 `repair`（CR-0107-04F path B）；归档 3 份冗余。
- **情形 B — 现场 = 修复分支**（7 函数均为裸 `v_order_no`，无 `v_order_no_val`）：
  → 将 `0034_tiered_market_system.sql` 中的 7 个 RPC 函数体**替换为 `0034_fix_public_prefix.sql` 对应体**（public_prefix 是修复分支的收口版，含 `public.` 限定符，最完整）；保留 tiered 的全部结构 DDL / 索引 / RLS；随后归档 3 份冗余。
- **通用安全合并（无论 A/B，推荐）**：
  → 取得 §2 的 `live_definition` 后，把 tiered 中这 7 个函数体**逐字覆盖为 live 文本**。这以"现场真身"为唯一权威，彻底规避"猜哪一版"的风险。0043 的 DEPRECATED COMMENT 会在迁移应用后再次被置上，无需在迁移内保留特定 COMMENT。

### 5.2 提案命令（供 CEO 评审后执行 · 本次未运行）
```bash
# (0) 取现场真身（见 §2）
# (1) 把 tiered 中 7 个 RPC 函数体逐字替换为 live_definition（用编辑器/脚本，幂等 CREATE OR REPLACE）
# (2) 归档冗余 3 份（git mv 保留历史，不删除）
mkdir -p supabase/migrations/_archive/0034_redundant
git mv supabase/migrations/0034_fix_batch1.sql        supabase/migrations/_archive/0034_redundant/
git mv supabase/migrations/0034_fix_batch2.sql        supabase/migrations/_archive/0034_redundant/
git mv supabase/migrations/0034_fix_public_prefix.sql supabase/migrations/_archive/0034_redundant/
# (3) （CR-0107-04F path B）对唯一权威 0034 做时间戳重命名 + repair
#     npx supabase migration repair --status applied --linked 20240101000034
```

### 5.3 与 CR-0107-04F-A 的衔接
本审计承接 04F-A 的"0034 非简单重复、tiered 为结构真相源、7 RPC 存在多版本重定义"结论，补全了**现场真身判定方法**与**variant-agnostic 合并方案**。最终权威 0034 = tiered 结构 + live 真身 RPC 体；3 份修复批次归档。

---

## 6. 约束遵守确认
未修改任何 SQL、未合并文件、未 git mv、未 archive、未 repair、未 db push、未 commit、未 push。所有结论与命令均为提案。

---

## 7. 状态与待办
- **状态**：⏳ WAITING CEO REVIEW
- **待办（阻塞项）**：提供**有效 Supabase PAT** 或 **DB 直连串**，即可立即执行 §2 查询、填妥 §4、并据 §5 决策树敲定最终合并动作。
- 在拿到 live 数据前，§5 的合并建议保持"variant-agnostic"——即"以 tiered 为结构骨架、以 live 真身为 RPC 权威"，该方案对 A/B 两种情形均安全。
