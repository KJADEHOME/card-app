# CR0107-04F-E · 归档 0034 冗余 Migration 执行计划（PREP ONLY）

> **任务性质**：仅生成执行计划，**不执行**。
> **状态**：⏳ WAITING CEO REVIEW
> **项目**：`D:\codex\cardrealm\card-app`
> **生成时间**：2026-08-05

---

## 1. 目标（Objective）

将 4 份旧 `0034_*.sql` 冗余 migration **移出** `supabase/migrations/` 扫描目录，归档至
`supabase/migrations/_archive/0034_redundant/`，消除 `0034` 版本号碰撞（"0034×4" 问题），
并保留新生成的权威文件 `20240101000034_tiered_market_system_authoritative.sql` 在 `migrations/` 内。

### 移动清单

| 源文件（均在 `supabase/migrations/`） | 大小 | 目标位置 |
|---|---|---|
| `0034_tiered_market_system.sql` | 56,230 B | `_archive/0034_redundant/` |
| `0034_fix_batch1.sql` | 7,282 B | `_archive/0034_redundant/` |
| `0034_fix_batch2.sql` | 9,093 B | `_archive/0034_redundant/` |
| `0034_fix_public_prefix.sql` | 16,376 B | `_archive/0034_redundant/` |

### 保留不动

- `supabase/migrations/20240101000034_tiered_market_system_authoritative.sql`（权威文件，留 `migrations/` 内供 CLI 识别）

---

## 2. 当前已验证状态（Pre-flight Facts）

| 检查项 | 结果 |
|---|---|
| 4 份旧 `0034_*` 文件存在性 | ✅ 全部存在 |
| 4 份旧文件 git 跟踪状态 | **TRACKED**（已提交，最新 commit `be78528` 批次） |
| `20240101000034_..._authoritative.sql` 状态 | 存在、**UNTRACKED**（04F-D 生成，尚未 `git add`） |
| `_archive/` 目录 | **不存在**（执行时需创建） |
| git 工作区对这 4 文件 | 干净（无未提交修改） |
| 远程 `schema_migrations` 是否有 `0034` version | 无（04F-A/B 已确认：现场 schema 由手工应用这 4 份产生，从未进入迁移追踪） |

---

## 3. 为何要归档（Why）

1. **消除版本号碰撞**：4 份文件版本前缀均为 `0034`，与权威文件 `20240101000034`（合成时间戳版 `0034`）在语义上冲突。`supabase migration list` 的 Local 列以 `version` 去重——保留 4 份 `0034_*` 会与已 repair 的 `20240101000034` 造成混淆与潜在 lint 告警。
2. **CLI 扫描净化**：`supabase migration list` / `db push` 仅扫描 `supabase/migrations/` **顶层** `.sql`。归档至 `_archive/` 子目录后，CLI 不再识别这 4 份，避免在任何 `db push` 中意外重放。
3. **历史可追溯**：保留源文件（不删除），未来如需审计"现场 0034 子系统真实演进"可随时回查。
4. **非破坏性**：因远程无 `0034` version，移动这些文件不影响任何已追踪的迁移历史或线上状态。

---

## 4. 前置检查（Pre-flight Checks · 执行前逐项确认）

- [ ] 工作区干净：`git status` 仅显示 `20240101000034_..._authoritative.sql` 为 `??`（untracked），4 份旧文件无修改。
- [ ] 已确认 `20240101000034_..._authoritative.sql` 内容经 04F-D 校验（8 函数各 1 次、4 替换=public_prefix、4 保留=tiered、结构计数不变）。
- [ ] 确认执行方式（见 §5 Method A/B 二选一）。
- [ ] 确认归档后**不会**立即触发 `db push` / `migration repair`（本任务禁止，且后续 04F path B 统一处理）。

---

## 5. 执行步骤（Execution Steps · 待 CEO 授权后运行）

### 目录创建

```bash
cd D:/codex/cardrealm/card-app/supabase/migrations
mkdir -p _archive/0034_redundant
```

### Method A — `git mv`（推荐，文件已 TRACKED，保留 rename 历史，最干净）

```bash
cd D:/codex/cardrealm/card-app/supabase/migrations
git mv 0034_tiered_market_system.sql \
       0034_fix_batch1.sql \
       0034_fix_batch2.sql \
       0034_fix_public_prefix.sql \
       _archive/0034_redundant/
```

> ⚠️ 若 CEO 仍禁止 `git mv`（延续本任务约束），改用 **Method B**。

### Method B — 普通 `mv` + `git rm --cached`（贴合本项目"避免 git mv"惯例）

```bash
cd D:/codex/cardrealm/card-app/supabase/migrations
git rm --cached 0034_tiered_market_system.sql \
              0034_fix_batch1.sql \
              0034_fix_batch2.sql \
              0034_fix_public_prefix.sql
mv 0034_tiered_market_system.sql \
   0034_fix_batch1.sql \
   0034_fix_batch2.sql \
   0034_fix_public_prefix.sql \
   _archive/0034_redundant/
git add _archive/0034_redundant/
```

> 说明：Method B 下 git 将旧路径视为 delete、新路径视为 add；因内容一致，
> `git log --follow` / `git diff -M` 仍能识别为 rename。历史不丢失。

### 归档后 `migrations/` 顶层应仅剩

- `20240101000034_tiered_market_system_authoritative.sql`（权威 0034）
- 其余 `00XX_*.sql` / `2026*.sql`（按 04F path B 后续统一重命名处理）

---

## 6. 验证（Verification · 本地、无需 DB 凭证）

| 步骤 | 命令 | 期望结果 |
|---|---|---|
| 目录确认 | `ls _archive/0034_redundant/` | 4 份旧文件均在 |
| 原目录净化 | `ls 0034_*.sql` | 无输出（4 份已移走） |
| 权威文件在位 | `ls 20240101000034_*.sql` | 仅 `20240101000034_tiered_market_system_authoritative.sql` |
| 内容无损 | `sha256sum _archive/0034_redundant/0034_*.sql` | 与移动前 4 份 sha256 **完全一致** |
| git 操作类型 | `git status --porcelain` | 显示 4 个 `R `（rename，Method A）或 `D`+`A`（Method B）；**不应**出现 `M` 修改 |
| CLI 不再识别 | `npx supabase migration list` | Local 列**不含**任何 `0034_*` 旧版本（仅 `20240101000034...`） |

> `supabase migration list` 的 Local 列为**纯本地目录读取**，不需要 DB 凭证即可验证扫描净化效果。

---

## 7. 与 04F path B 修复流程的衔接（Critical）

归档**只解决本地文件碰撞**。要让权威 `20240101000034` 被 CLI 承认为"已应用"，
必须（在后续授权步骤中）执行：

1. 按 04F path B 将余下 `00XX` 文件重命名为 `202401010000XX` 合成时间戳格式。
2. `supabase migration repair --status applied 20240101000034 <其余 58 个时间戳 version>`
   —— **仅写 `schema_migrations` 历史，不执行 SQL**（官方确认）。
3. **验收**：`supabase migration list` 中 Local 与 Remote 列对齐、`20240101000034` 标记 applied。

> ⚠️ **不可在 `repair` 之前运行 `supabase db push`**：
> 未 repair 时 CLI 会把 `20240101000034` 视为"待应用"并尝试重放。
> 虽权威文件已用 `IF NOT EXISTS` / `CREATE OR REPLACE`（表 4 ✅ / 视图 ✅ / 索引 ✅ / 函数 ✅ 均幂等），
> 重放不会破坏数据，但会产生冗余执行噪声与潜在告警。故 `repair` 为强制前置门。

---

## 8. 风险与回滚（Risk & Rollback）

| 风险 | 可能性 | 缓解 |
|---|---|---|
| 移动后误 `db push` 重放 `20240101000034` | 中 | 严格先 `repair` 后 `push`；文件本身幂等 |
| `_archive/` 被 CLI 递归扫描 | 低 | Supabase CLI 不递归 `migrations/` 子目录；用 §6 `migration list` 验证 |
| git 历史丢失 | 极低 | Method A 保留 rename；Method B 内容一致可被 `-M` 识别；文件未删除 |
| 误归档权威文件 | 无 | 本计划仅移动 4 份 `0034_*`，保留 `20240101000034_*` |

**回滚**：`git mv` / `mv` 反向操作即可（从 `_archive/0034_redundant/` 移回 `migrations/` + `git add`）。文件未删除，回滚零风险。

---

## 9. 验收标准（Acceptance）

- [ ] `_archive/0034_redundant/` 含 4 份旧 `0034_*.sql`，sha256 与移动前一致。
- [ ] `supabase/migrations/` 顶层**不再有**任何 `0034_*.sql`（旧版）。
- [ ] `20240101000034_tiered_market_system_authoritative.sql` 仍在 `migrations/` 顶层。
- [ ] `git status` 无意外修改（`M`），仅 rename/delete+add。
- [ ] `npx supabase migration list` Local 列不含旧 `0034_*`。
- [ ] 未触发 `db push` / `migration repair` / `commit` / `push`（本任务范围外）。

---

## 10. 明确不在本任务范围（Out of Scope）

- ❌ 不执行 `git mv` / `mv` / `git rm` / `git add`（本任务仅出计划）。
- ❌ 不执行 `migration repair`、`db push`、`commit`、`push`。
- ❌ 不修改任何 SQL 内容（包括权威文件）。
- ❌ 不处理其余 `00XX` 文件的 path B 重命名（属 04F path B 后续步骤）。
- ❌ 不修改远程数据库。

---

## 11. 后续衔接清单（供 CEO 决策）

| 序号 | 动作 | 依赖 | 授权状态 |
|---|---|---|---|
| 1 | 执行本计划 §5（归档 4 份旧 0034） | — | 待授权 |
| 2 | `git add` 权威文件 + 归档变更（commit 前） | 步骤 1 | 待授权 |
| 3 | 04F path B：重命名余下 `00XX` → `202401010000XX` | 步骤 1 | 待授权 |
| 4 | `supabase migration repair --status applied` 59 个 version | 步骤 3 | 待授权（需有效 PAT） |
| 5 | `supabase migration list` 验收 Local/Remote 对齐 | 步骤 4 | 待授权 |
| 6 | （可选）`db push --dry-run` → `db push` 部署 03A-1 RLS + 3 本地独有迁移 | 步骤 4/5 | 待授权 |

---

*本计划严格遵循约束：未执行任何文件移动 / git 操作 / 数据库操作。所有命令仅供 CEO 评审通过后由后续授权步骤执行。*
