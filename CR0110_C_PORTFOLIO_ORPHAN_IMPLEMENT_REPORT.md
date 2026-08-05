# CR-0110-C 实施报告：portfolio_items identity orphan 清理

> 状态：**实施完成（仅新增迁移文件，未部署）** · WAITING CEO REVIEW
> 关联：DH-1（CR-0107-04F-U 冒烟测试发现）；CR-0110-B（方案已批准，采用 MVP = ①+②+④）
> 项目：`D:\codex\cardrealm\card-app`（分支 `release-beta-preparation`，Beta ref `xybpcsmjjcnkjwfsuder`）
> 生成时间：2026-08-05 21:33 (GMT+8)

---

## 1. 交付物

| 项目 | 内容 |
|------|------|
| 新增迁移 | `supabase/migrations/20260805213000_portfolio_identity_orphan_cleanup.sql` |
| 排序位置 | 在 `20260805170000`（owner-check，已部署）之后，本地 70 个迁移 |
| 改动性质 | **仅新增**，未触碰任何历史迁移（含 `20260802113000`、`2024010100000021/0051/0052`） |
| 产出文件 | 本 `CR0110_C_PORTFOLIO_ORPHAN_IMPLEMENT_REPORT.md` |

---

## 2. 采用的方案：CR-0110-B 批准的 MVP（① + ② + ④）

| 编号 | 覆盖孤儿源 | 实现位置 | 说明 |
|------|-----------|----------|------|
| **①** | Source B（identity 列 UPDATE） + Source C（存量） | 改造 `sync_collections_to_portfolio()` | upsert 后追加 orphan DELETE |
| **②** | Source A（`user_collections` 整行 DELETE） | 新增 `trg_collection_delete_cleanup_portfolio` 触发器 | `AFTER DELETE` → 重跑该用户 sync |
| **④** | Source C（存量回填） | 新增 `cleanup_portfolio_orphans()` | **仅定义，不执行**（受禁令约束） |

未纳入（按方案为可选增强，非 MVP）：③ 触发器错误分支整理、⑤ 周期性清理任务。

---

## 3. identity 8 列 与 COALESCE 映射一致性（强制要求）

**identity 8 列**（`portfolio_items_identity_key` 唯一约束）：
`user_id, card_name, series, rarity, product_code, region, edition, packaging_type`

**COALESCE 映射**（三处必须一致：GROUP BY / 唯一键 / 清理条件）——本迁移完全复用 `20260802113000` 的映射，未改动：

| 列 | COALESCE 默认值 | 说明 |
|----|----------------|------|
| `card_name` | （不 COALESCE） | `user_collections.card_name` 为 `TEXT NOT NULL`（见 `2024010100000004` L10），唯一键亦不含 COALESCE |
| `user_id` | （不 COALESCE） | FK NOT NULL |
| `series` | `''` | `COALESCE(uc.series, '')` |
| `rarity` | `'N'` | `COALESCE(uc.rarity, 'N')` |
| `product_code` | `''` | `COALESCE(uc.product_code, '')` |
| `region` | `'UNKNOWN'` | `COALESCE(uc.region, 'UNKNOWN')` |
| `edition` | `'Unknown'` | `COALESCE(uc.edition, 'Unknown')` |
| `packaging_type` | `'card'` | `COALESCE(uc.packaging_type, 'card')` |

**一致性核验**：本迁移内 orphan DELETE 的 `NOT EXISTS` 子查询所用 COALESCE 映射，与 `20260802113000` 第 39–54 行 `GROUP BY` / 第 27–28 行唯一约束**逐列一致**。`pi.*`（portfolio_items 行）已存储 coalesced 值，故比较式写作 `COALESCE(uc.x, <默认>) = pi.x`（例：`COALESCE(uc.series,'') = pi.series`），等价且无误伤。

---

## 4. 关键实现决策

### 4.1 ① `sync_collections_to_portfolio()` —— upsert 后 orphan DELETE
- 原 `INSERT … ON CONFLICT DO UPDATE` 逻辑与 `20260802113000` **逐字节一致**（含 `card_market` LATERAL JOIN、列清单、`updated_at=NOW()`）。
- `GET DIAGNOSTICS v_count = ROW_COUNT` 置于 orphan DELETE **之前**，确保 `items_synced` 仍返回 upsert 行数（符合方案"返回 upsert 行数"语义）。
- **scoped 分支**（`p_user_id IS NOT NULL`）：单条 `DELETE … WHERE pi.user_id = p_user_id AND NOT EXISTS(...)`，由调用方触发器已持有的 per-user advisory 锁保护。
- **full 分支**（`p_user_id IS NULL`）：按 `DISTINCT user_id ORDER BY user_id` 循环，逐用户加 `pg_advisory_xact_lock` 后 DELETE —— 避免单条全表长锁（方案 R2/R5），且锁按固定顺序获取，排除并发全量 sync 死锁。

### 4.2 ② `trg_collection_delete_cleanup_portfolio` —— `AFTER DELETE` 触发器
- **设计为调用 `sync_collections_to_portfolio(OLD.user_id)`，而非直接按 OLD 删除 portfolio 行**。原因：同一 identity 可能对应多条 `user_collections` 行；直接按 OLD 删除会误删"仍有其余行匹配"的 portfolio 项。改由 sync 重聚合剩余行、其内置 ① orphan DELETE 精确清除真正孤儿。
- 触发器内先 `pg_advisory_xact_lock(OLD.user_id)` 再 `PERFORM sync(...)`，与 `trg_collection_auto_sync_portfolio`（INSERT/UPDATE）共用同一把锁，无并发竞争；同事务内重复加同一把 xact 锁为幂等，无死锁。
- 无递归：`sync` 只 `SELECT` `user_collections` + 写 `portfolio_items`；删除 portfolio 行触发 `trg_portfolio_auto_refresh`（刷新 `user_portfolio` 总览，为预期收益），不回写 `user_collections`。

### 4.3 ④ `cleanup_portfolio_orphans()` —— 一次性存量清理（**仅定义**）
- 全表 `DELETE … WHERE NOT EXISTS(...)`，COALESCE 映射同上。
- **本迁移不执行**（受禁令"执行历史清理"约束）。部署后由运维以 `service_role` 在**低峰窗口**手动运行：
  ```sql
  SELECT * FROM public.cleanup_portfolio_orphans();   -- 返回 orphans_removed
  ```
- 运行前可先用源 C 统计语句估算影响面（见 §7）。

### 4.4 权限
- `cleanup_portfolio_on_collection_delete()`、`cleanup_portfolio_orphans()` 均 `SECURITY DEFINER` + `SET search_path=''`（防搜索路径注入）。
- 两个函数均 `REVOKE ALL … FROM PUBLIC, anon, authenticated`：触发器函数以定义者身份运行无需用户 EXECUTE 权限；`cleanup_portfolio_orphans()` 仅为运维函数（service_role 可调）。与既有 `auto_sync_collection_to_portfolio()` 的 REVOKE 风格一致。

---

## 5. SQL 语法验证（要求 5）

**环境限制**：本机无 Docker、无本地 Postgres、`supabase db lint`（需本地 Docker 栈）不可用。故采用 **pgsql-parser（libpg_query WASM）** 对迁移文件做静态解析 + 人工复核。

### 5.1 解析结果
- 工具：`pgsql-parser`（`parseSync`，加载 WASM 模块后解析全脚本）。
- 结果：**10 条语句全部 PARSE OK，无语法错误**。
  ```
  TransactionStmt | CreateFunctionStmt(sync) | CommentStmt
  | CreateFunctionStmt(trigger fn) | DropStmt | CreateTrigStmt
  | CreateFunctionStmt(cleanup_orphans) | GrantStmt | GrantStmt | TransactionStmt
  ```
- 印证外层 DDL 结构合法：dollar-quote（`$$`）成对、括号配平、语句分隔正确。

### 5.2 人工复核（捕获并修复 1 个真实语法缺陷）
- **缺陷**：初版 `sync_collections_to_portfolio()` 函数体开头误写两个 `DECLARE` 块（`DECLARE v_count …; DECLARE v_uid …;`）——PL/pgSQL **仅允许一个 `DECLARE` 区**。解析器不深入 plpgsql 函数体字符串，故该缺陷由人工复核发现，已修复为单一 `DECLARE` 区（`v_count` 与 `v_uid` 合并）。
- 其余 plpgsql 结构复核：`BEGIN/END`、`IF…END IF`、`FOR…LOOP/END LOOP`、各函数 `DECLARE` 区数量均正确；COALESCE 映射与 GROUP BY / 唯一键三处一致。

### 5.3 验证局限（透明披露）
- libpg_query 将函数体视为字符串字面量，**不深入校验 plpgsql 内部 SQL 语义**（如表/列存在性、类型匹配）。
- **语义级验证（Beta 运行时）不在本任务范围**，应由后续部署/验证任务（对应 CR-0110-B §7 的"部署后验证"）在 Beta 以 `--linked` 执行 TC-1/2/3 完成。本任务严格遵守"不 db push"。

---

## 6. 遵守的禁令（要求：禁止项）

| 禁令 | 是否遵守 | 说明 |
|------|----------|------|
| 修改历史 migration | ✅ 遵守 | 仅新增 `20260805213000_...sql`；`20260802113000` 等历史文件零改动 |
| `db push` | ✅ 遵守 | 未推送；迁移停留在本地，待 CEO 复核后由部署任务推送 |
| `git push` | ✅ 遵守 | 未推送远程；本报告亦未 commit（等 CEO 决定是否纳入提交） |
| 执行历史清理 | ✅ 遵守 | `cleanup_portfolio_orphans()` 仅定义，**未运行**；无任何 `DELETE`/`SELECT … INTO` 清理被执行 |

---

## 7. 部署后验证建议（对应 CR-0110-B §7，由后续任务执行）

1. **源 A 单元**：建测试收藏 → `DELETE` 整行 → 断言对应 `portfolio_items` 行归零且 `user_portfolio` 总览同步下降。
2. **源 B 单元**：建 `Solo-Card/UNKNOWN=5` → `UPDATE` 改为 `JP` → 断言仅剩 `Solo-Card/JP`，无 `UNKNOWN` 孤儿。
3. **源 C 存量**：部署前 `SELECT count(*)` 统计孤儿（左联同 identity 元组无匹配）；回填 ④ 后复测 = 0。
   ```sql
   -- 孤儿统计（部署前/后对比用）
   SELECT count(*) FROM public.portfolio_items pi
   WHERE NOT EXISTS (
     SELECT 1 FROM public.user_collections uc
     WHERE uc.user_id=pi.user_id AND uc.card_name=pi.card_name
       AND COALESCE(uc.series,'')=pi.series AND COALESCE(uc.rarity,'N')=pi.rarity
       AND COALESCE(uc.product_code,'')=pi.product_code AND COALESCE(uc.region,'UNKNOWN')=pi.region
       AND COALESCE(uc.edition,'Unknown')=pi.edition AND COALESCE(uc.packaging_type,'card')=pi.packaging_type
   );
   ```
4. **回归**：重跑 04F-U 的 TC-1.1~1.6、TC-3.3，断言 `items_synced` 与 portfolio 行数一致、无孤儿。
5. **负荷**：④ 全量回填观察 `trg_portfolio_auto_refresh` 与 DB 负载，确认无长事务/锁等待。

---

## 8. 待 CEO 复核决策点

1. 是否以本新增迁移（`20260805213000_...sql`）作为 DH-1 修复落地文件，纳入提交并后续部署？
2. ④ 一次性回填的执行窗口（低峰）与回滚预案确认（回滚 = `DROP TRIGGER` + `CREATE OR REPLACE` 还原旧函数，或直接 `supabase db push` 反向迁移）。
3. 是否一并采纳可选增强：③ 清理触发器错误分支冗余 DELETE、⑤ 周期性清理（方案 Y：Edge Function 分批，推荐）。
4. ⑤ 若采纳，选 pg_cron（X）还是 Edge Function 分批（Y，推荐，无扩展依赖）。

---

## 9. 文件清单

- 新增：`D:\codex\cardrealm\card-app\supabase\migrations\20260805213000_portfolio_identity_orphan_cleanup.sql`
- 输出：`D:\codex\cardrealm\card-app\CR0110_C_PORTFOLIO_ORPHAN_IMPLEMENT_REPORT.md`
- 未改动：所有历史迁移、`CR0110_B_PORTFOLIO_ORPHAN_PLAN.md`、`CR0110_A_*`、`CR0110_C_ORDER_OWNER_DEPLOY_REPORT.md`

**状态：待 CEO 复核** —— 本任务为代码实施（新增迁移）+ 语法验证，**未部署、未推送、未执行历史清理**。建议复核后决定是否 commit 并排入 Beta 部署验证（CR-0110-D）。
