# CR-0107-04F-B2 — RPC Source Final Mapping Report

**项目**: `D:\codex\cardrealm\card-app`
**状态**: ⏳ WAITING CEO REVIEW（**live DB 不可达，5 个 RPC 判定为 UNRESOLVED**）
**上游**: CR-0107-04F-C（authoritative 方案）已完成 · 本任务要求读 live `pg_get_functiondef` 钉死剩余 5 RPC

---

## 0. 结论摘要

| 项目 | 结果 |
|---|---|
| 能否读取 live DB `pg_get_functiondef` | ❌ **不能** — 凭据全部失效/缺失 |
| 剩余 5 RPC 判定（tiered / public_prefix） | ⚠️ **UNRESOLVED（待 live 查询）** |
| 已确认（来自 04F-C，非本次读取） | `create_sealed_product_order`=tiered · `create_merchandise_order`=tiered |

> **本报告不臆测判定**。5 个 RPC 的 live 真身必须来自实时 `pg_get_functiondef`，本环境无法取得，故如实标注 UNRESOLVED，并附**即取即判**的查询与判定规则，CEO 取得凭据后可 1 分钟内填妥。

---

## 1. 连接尝试（本次实测，全部失败）

| # | 方法 | 命令/来源 | 结果 |
|---|---|---|---|
| 1 | PAT + `supabase link` | `link --project-ref xybpcsmjjcnkjwfsuder` | `{"message":"Unauthorized"}` ❌ |
| 2 | `supabase db query --linked` | 利用 `supabase/.temp/linked-project.json` | `Cannot find project ref. Have you run supabase link?` ❌（CLI v2.111 忽略该 .temp 文件） |
| 3 | 直接 DB URL / `psql` | 搜索 `.env*` / `config.toml` / `~/.pgpass` | 无任何 `postgres://` 串 / 无密码 / 无 `psql` 二进制 ❌ |
| 4 | 本地 Supabase 栈 | `supabase status` + 端口探测 | Docker/Podman 未装 → 无本地库、无 5432/54322/6543 监听 ❌ |

### 1.1 凭据资产盘点（masked）
- `~/.supabase/access-token`：**不存在**
- `~/.pgpass`：**不存在**
- `SUPABASE_ACCESS_TOKEN` 环境变量：**未设**
- `.env.local`：仅 `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=` / `CLERK_SECRET_KEY=`（非 Supabase）
- `.env.example`：`SUPABASE_SERVICE_ROLE_KEY=`（**空值占位**）
- `supabase/config.toml`：无 `connection_string` / 无密码
- `supabase/.temp/linked-project.json`：仅含 `ref`/`name`/`organization_id`（**无 token**）

→ **唯一可用凭据是已过期 PAT**，远程查询全面受阻；无本地库可替代。

---

## 2. 为何不能"从文件名/应用顺序"推断（重要）

`0034_*` 四个文件被**手动**应用到生产（远程 `schema_migrations` 无 0034 version，见 04F-A）。应用顺序未知。

**但用户的 04F-C 确认已证伪"文件名顺序"假设**：
- `0034_fix_public_prefix.sql`（修复分支，最后/收口文件）也定义了 `create_sealed_product_order` 与 `create_merchandise_order`；
- 而 04F-C 确认这两者 live = **tiered**（非 public_prefix）。

→ 说明生产应用顺序**并非简单文件名序**，且 live 为真实混合态。**任何基于文件名的推断都不可靠、会出错**，必须以 live `pg_get_functiondef` 为准。

---

## 3. 逐 RPC 判定表（待 live 查询填妥）

| # | RPC | 判断（tiered / public_prefix） | 依据（4 个标记，见 §4） | 状态 |
|---|---|---|---|---|
| 1 | `admin_update_sealed_product` | **UNRESOLVED** | 待 live `pg_get_functiondef` 比对 §4 标记 | ⏳ |
| 2 | `cancel_sealed_product_order` | **UNRESOLVED** | 同上 | ⏳ |
| 3 | `admin_confirm_sealed_order` | **UNRESOLVED** | 同上 | ⏳ |
| 4 | `admin_create_merchandise` | **UNRESOLVED** | 同上 | ⏳ |
| 5 | `admin_update_merchandise` | **UNRESOLVED** | 同上 | ⏳ |

> 已确认（carry-over，非本次读取）：`create_sealed_product_order`=tiered · `create_merchandise_order`=tiered（04F-C）。
> 用户原述"部分 admin/cancel RPC = 修复分支" → #1–#5 中至少一、至多五个为 public_prefix，但**具体归属须 live 数据决定，本报告不猜**。

---

## 4. 判定规则（body 级，已在 04F-C 实测验证）

对 live `pg_get_functiondef` 返回体，按以下标记判定：

| 标记 | tiered 变体 | 修复分支（public_prefix）变体 |
|---|---|---|
| `#variable_conflict use_column` 指令 | ✅ 含 | ❌ 无 |
| 序号变量命名 | `v_order_no_val` | `v_order_no`（无 `_val`） |
| `COMMENT ON FUNCTION ... IS` | ✅ 含 | ❌ 无 |
| UUID 调用 | `extensions.gen_random_uuid()` | `gen_random_uuid()`（无 `extensions.`） |

**判定逻辑**：
- live 体含 **任一** tiered 标记（`#variable_conflict` / `v_order_no_val` / `COMMENT ON FUNCTION` / `extensions.gen_random_uuid()`）→ 来源 = **tiered**
- live 体用 `v_order_no`（无 `_val`）且 `gen_random_uuid()`（无 `extensions.`）且无 `#variable_conflict` 且无 `COMMENT ON` → 来源 = **修复分支（public_prefix）**

> ⚠️ `public.` 模式限定**不是**判别符（两变体都大量使用，tiered 甚至更多）——已排除。

---

## 5. 即取即判查询（取得凭据后运行）

```sql
-- 取得 5 个 RPC 的 live 定义（输出含完整函数体）
SELECT
  p.proname,
  pg_get_functiondef(p.oid) AS def
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'admin_update_sealed_product',
    'cancel_sealed_product_order',
    'admin_confirm_sealed_order',
    'admin_create_merchandise',
    'admin_update_merchandise'
  )
ORDER BY p.proname;
```

**运行方式（任一，均需有效凭据）**：
```bash
# 方式 A：Management API + 有效 PAT
export SUPABASE_ACCESS_TOKEN="<有效PAT>"
npx supabase db query --project-ref xybpcsmjjcnkjwfsuder -f q_rpc5.sql

# 方式 B：直连（需 DB 密码，绕过 PAT）
psql "postgresql://postgres.<ref>:<DB_PASSWORD>@aws-0-<region>.pooler.supabase.com:6543/postgres" -f q_rpc5.sql
```

**填表**：将每个 `def` 按 §4 标记比对 → 写入 §3 判定列 → 回灌 04F-C §2.1 映射表 → 即可执行 04F-C §3 的权威文件构建。

---

## 6. 待 CEO 提供（解封阻塞）

二选一即可：
1. **有效 Supabase PAT**（`sbp_...`，对 `db query` 授权）
2. **DB 直连串**（`postgresql://postgres:<PWD>@db.xybpcsmjjcnkjwfsuder.supabase.co:5432/postgres` 或 pooler `:6543`）

取得后，本任务可在不修改任何文件的前提下完成 §3 填表（本任务约束仍禁止修改 SQL / 合并 / git mv / archive / repair / db push / commit / push）。

---

## 7. 约束合规性确认

| 禁止项 | 是否触碰 |
|---|---|
| 修改 SQL | ❌ 否 |
| 合并 migration | ❌ 否 |
| git mv | ❌ 否 |
| archive | ❌ 否 |
| repair | ❌ 否 |
| db push | ❌ 否 |
| commit | ❌ 否 |
| push | ❌ 否 |

本次仅读取凭据资产 + 尝试连接 + 产出本报告，**未改动任何文件、未连接成功**。

---

**状态**: ⏳ WAITING CEO REVIEW（UNRESOLVED — 需有效凭据以读取 live `pg_get_functiondef`）
