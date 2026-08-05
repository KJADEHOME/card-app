# CR107-04F-E · 归档 0034 冗余 Migration 执行报告

> **任务性质**：执行 CR0107-04F-E 归档计划（已获 CEO 授权）
> **状态**：⏳ WAITING CEO REVIEW
> **项目**：`D:\codex\cardrealm\card-app`
> **执行时间**：2026-08-05 11:03 (GMT+8)
> **执行方法**：Method A — `git mv`（按授权书允许项）

---

## 1. 授权范围（Granted Permissions）

- ✅ 创建 `_archive/0034_redundant/`
- ✅ `git mv` 四个旧 `0034_*` migration
- ❌ 禁止：`db push` / `migration repair` / `commit` / `push`（均**未执行**）

---

## 2. 执行的操作（Executed Actions）

```bash
cd D:/codex/cardrealm/card-app/supabase/migrations

# 1) 创建归档目录
mkdir -p _archive/0034_redundant

# 2) git mv 四个旧 0034 文件到归档目录
git mv 0034_tiered_market_system.sql \
       0034_fix_batch1.sql \
       0034_fix_batch2.sql \
       0034_fix_public_prefix.sql \
       _archive/0034_redundant/
# GIT_MV_EXIT=0
```

**保留未动**：`20240101000034_tiered_market_system_authoritative.sql`（仍在 `migrations/` 顶层）。

---

## 3. 执行后验证（Post-execution Verification）

### 3.1 git status（本任务产生的变更）

`git status --porcelain` 中，**本任务专属产出**为以下 4 行 rename（`R `）：

```
R  supabase/migrations/0034_fix_batch1.sql              -> supabase/migrations/_archive/0034_redundant/0034_fix_batch1.sql
R  supabase/migrations/0034_fix_batch2.sql              -> supabase/migrations/_archive/0034_redundant/0034_fix_batch2.sql
R  supabase/migrations/0034_fix_public_prefix.sql       -> supabase/migrations/_archive/0034_redundant/0034_fix_public_prefix.sql
R  supabase/migrations/0034_tiered_market_system.sql    -> supabase/migrations/_archive/0034_redundant/0034_tiered_market_system.sql
```

> ✅ 4 个文件均为 `R`（rename），**无任何 `M`（修改）**——确认纯移动、内容未改。
> 注：`git status` 输出中其余 `M`/`D`/`??` 条目为**本任务之前**已存在的工作区状态（历史各 CR 任务遗留），与本次归档无关。

### 3.2 归档文件存在性

```
_archive/0034_redundant/
├── 0034_fix_batch1.sql       7,282 B
├── 0034_fix_batch2.sql       9,093 B
├── 0034_fix_public_prefix.sql 16,376 B
└── 0034_tiered_market_system.sql 56,230 B
```

✅ 4 份旧文件均已在归档目录，大小与移动前一致。

### 3.3 顶层无旧 `0034_*.sql`

```bash
ls 0034_*.sql
# ls: cannot access '0034_*.sql': No such file or directory
```

✅ `migrations/` 顶层已无任何 `0034_*.sql`（旧版碰撞源已清除）。

### 3.4 权威文件仍存在

```
supabase/migrations/20240101000034_tiered_market_system_authoritative.sql  57,033 B
```

✅ 权威文件保留在 `migrations/` 顶层，供 CLI 识别。

### 3.5 内容完整性（sha256 字节级校验）

| 文件 | 移动前 sha256 | 移动后 sha256 | 一致 |
|---|---|---|---|
| `0034_tiered_market_system.sql` | `b37919a0…c0f90a` | `b37919a0…c0f90a` | ✅ |
| `0034_fix_batch1.sql` | `1fab81ae…38adfb` | `1fab81ae…38adfb` | ✅ |
| `0034_fix_batch2.sql` | `f3e04dba…ca10e25` | `f3e04dba…ca10e25` | ✅ |
| `0034_fix_public_prefix.sql` | `32bf0444…6c744f` | `32bf0444…6c744f` | ✅ |

> 比较 hash-only 列：`HASHES_IDENTICAL_OK`（内容逐字节未变，`git mv` 不修改文件内容）。

---

## 4. CLI 扫描净化（Local 等价验证）

`supabase/migrations/` 顶层已无 `0034_*.sql`，故 `supabase migration list` 的 **Local 列不会再出现旧 `0034_*` 版本**。

> 注：`supabase migration list` 的完整 Local/Remote 对齐验证需有效 Supabase PAT（当前 PAT 已过期，见 04F-B），
> 该步骤归属 **04F path B** 的 `migration repair` + `migration list` 验收流程，不在本任务范围。
> 本任务的本地前置目标（顶层无旧 `0034_*`）已达成。

---

## 5. 约束遵守确认（Constraints Compliance）

| 禁止项 | 是否触碰 |
|---|---|
| `db push` | ❌ 未执行 |
| `migration repair` | ❌ 未执行 |
| `commit` | ❌ 未执行 |
| `push` | ❌ 未执行 |
| 删除文件 | ❌ 未删除（仅移动归档） |
| 修改 SQL 内容 | ❌ 未修改（sha256 一致） |

✅ 全部禁止项均遵守。

---

## 6. 交接与后续（Handoff / Next Steps）

| 序号 | 动作 | 依赖 | 状态 |
|---|---|---|---|
| 1 | 本任务：归档 4 份旧 0034（rename，未 commit） | — | ✅ 完成（待 commit 授权） |
| 2 | `git add` 归档变更 + 权威文件（commit 前） | 步骤 1 | 待授权 |
| 3 | 04F path B：重命名余下 `00XX` → `202401010000XX` | 步骤 1 | 待授权 |
| 4 | `supabase migration repair --status applied` 59 版本（含 `20240101000034`） | 步骤 3 + 有效 PAT | 待授权 |
| 5 | `supabase migration list` 验收 Local/Remote 对齐 | 步骤 4 | 待授权 |
| 6 | （可选）`db push --dry-run` → `db push` 部署 03A-1 RLS + 3 本地独有迁移 | 步骤 4/5 | 待授权 |

> ⚠️ **关键提醒**：步骤 4 的 `repair` 必须在任何 `db push` 之前完成，否则 CLI 会将
> `20240101000034`（权威 0034）视为"待应用"并重放（文件本身幂等，但产生噪声）。

---

## 7. 结论（Conclusion）

✅ 4 份旧 `0034_*.sql` 已通过 `git mv` 干净归档至 `_archive/0034_redundant/`，内容逐字节不变（sha256 一致），
`migrations/` 顶层版本碰撞已消除，权威文件 `20240101000034_tiered_market_system_authoritative.sql` 保留在位。
本任务未触及远程数据库、未执行 `db push` / `repair` / `commit` / `push`。

状态：**⏳ WAITING CEO REVIEW**（建议批准后续步骤 2→6，衔接 04F path B 统一 tracking 修复）。
