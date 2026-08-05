# CR-0107-04F-D — Authoritative 0034 Migration Build Report

**项目**: `D:\codex\cardrealm\card-app`
**状态**: ⏳ WAITING CEO REVIEW（草稿已生成，未部署/未提交）
**上游**: CR-0107-04F-B2（mapping 确认）· CR-0107-04F-C（方案）

---

## 0. 约束与范围声明

| 禁止项 | 是否触碰 |
|---|---|
| 修改远程数据库 | ❌ 否 |
| db push | ❌ 否 |
| migration repair | ❌ 否 |
| git mv | ❌ 否 |
| archive | ❌ 否 |
| commit | ❌ 否 |
| push | ❌ 否 |

**写入新本地草稿文件是允许的**（禁止项不含"创建本地草稿"）。本任务产出 `supabase/migrations/20240101000034_tiered_market_system_authoritative.sql`。

---

## 1. 应用的来源映射（来自本任务输入）

| # | 函数 | 动作 | 来源 |
|---|---|---|---|
| 1 | `admin_create_sealed_product` | **KEEP** | tiered |
| 2 | `create_sealed_product_order` | **KEEP** | tiered |
| 3 | `admin_create_merchandise` | **KEEP** | tiered |
| 4 | `create_merchandise_order` | **KEEP** | tiered |
| 5 | `admin_update_sealed_product` | **REPLACE** | public_prefix（live） |
| 6 | `cancel_sealed_product_order` | **REPLACE** | public_prefix（live） |
| 7 | `admin_confirm_sealed_order` | **REPLACE** | public_prefix（live） |
| 8 | `admin_update_merchandise` | **REPLACE** | public_prefix（live） |

> 映射由用户在本任务输入中确认（"0034 live RPC mapping 已确认"）。构建忠实应用该映射。

---

## 2. 构建方法

1. **基础** = `0034_tiered_market_system.sql` 全文（4 表 / 5 视图 / 11 索引 / 8 策略 / 8 函数 / 全部 ALTER·DROP 演进）。
2. **4 个 REPLACE 函数**：将其 `CREATE OR REPLACE FUNCTION ... $func$ LANGUAGE plpgsql ... ;` 整块替换为 `0034_fix_public_prefix.sql` 中对应函数块。
3. **删除 4 个 REPLACE 函数尾部 `COMMENT ON FUNCTION ...`**（live public_prefix 无 COMMENT；tiered 有 → 必须删除以匹配 live）。
4. **4 个 KEEP 函数**：原样保留（含其 `COMMENT ON FUNCTION`）。
5. **结构 DDL**：全部来自 tiered，未动。

> 替换块取自 `public_prefix` 原文；因两文件闭包风格不同（tiered 用 `$func$;`，public_prefix 用 `$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';`），脚本按"第二个 `$func$` 定界符 + 其后首个 `;`"精确截取，确保完整且字节一致。

---

## 3. 验证结果（ALL_OK = True）

| 检查项 | 结果 |
|---|---|
| 8 个函数各定义 1 次（无重复） | ✅ |
| 4 个 REPLACE 函数体 **字节级 == public_prefix** | ✅ 全 True |
| 4 个 KEEP 函数体 **字节级 == tiered** | ✅ 全 True |
| 4 个 REPLACE 函数的 `COMMENT ON` 已删除 | ✅ 全 False（无残留） |
| 4 个 KEEP 函数的 `COMMENT ON` 保留 | ✅ 各 1 |
| 结构计数不变（tiered → 生成） | ✅ 4 表 / 5 视图 / 11 索引 / 8 策略 / 31 ALTER / 7 DROP 表 / 17 DROP 函数 / 4 DROP 视图 |
| 语义标记：REPLACE 呈 public_prefix 特征（`v_order_no_val=0` / `#variable_conflict=0`） | ✅ |
| 语义标记：KEEP 呈 tiered 特征（`#variable_conflict=1`；2 个 order 函数含 `v_order_no_val`） | ✅ |

**语法完整性**：生成块直接取自两份**已在生产成功执行**的源文件，语法正确性继承自有保障。

**产物规模**：1,201 行 / 55,832 字节。

---

## 4. 重要提示（部署前必读）

### 4.1 旧 0034 文件仍并存（未归档，因 archive 禁止）
当前 `supabase/migrations/` 同时存在：
```
0034_tiered_market_system.sql        （基础，已并入权威文件）
0034_fix_batch1.sql                  （冗余）
0034_fix_batch2.sql                  （冗余）
0034_fix_public_prefix.sql           （冗余）
20240101000034_tiered_market_system_authoritative.sql  （新权威）
```
- 4 个旧文件现已**全部冗余**（其内容已被权威文件覆盖）。
- **禁止 db push / migration repair** 直至旧文件按 04F-C §4 归档（`git mv` 至 `_archive/0034_redundant/`）——但本任务 archive 被禁，故留待未来授权步骤。

### 4.2 文件名与 04F path B 对齐
`20240101000034_*` 采用 04F 的合成时间戳格式，可被 CLI 识别。旧 `0034_*`（数字前缀）不被 CLI 识别（见 04F-C），二者 version 字符串不同，当前无即时碰撞；但旧文件须在部署前清出 `migrations/`。

### 4.3 未提交/未推送
草稿仅落盘本地，未 `commit`/`push`（约束）。

---

## 5. 下一步（均需逐条另行授权）

1. （可选）语法二次校验：`pgsql-parser` / 目标 PG 17 解析。
2. 归档 4 个旧 `0034_*` → `_archive/0034_redundant/`（git mv）。
3. 按 CR-0107-04F path B：重命名余下 `00XX`→`202401010000XX` + `migration repair --status applied`（59 version）。
4. `supabase migration list` 验收 Local/Remote 对齐。
5. （可选、授权后）`db reset` 后按 04F-C §5 比对 live：结构 + 7 RPC `pg_get_functiondef` 逐字节一致。

---

## 6. 约束合规性确认
全部禁止项（修改远程库 / db push / repair / git mv / archive / commit / push）**本次均未执行**。仅新增 1 个本地草稿文件。

---

**状态**: ⏳ WAITING CEO REVIEW
