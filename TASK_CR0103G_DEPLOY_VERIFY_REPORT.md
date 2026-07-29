# TASK-CR-0103-G — Beta Deployment Verification Report

**Project:** Cardrealm Beta (PWA + Supabase)
**Repo path:** `D:/codex/cardrealm/card-app/`
**Deploy target (human-confirmed):** Supabase Project Ref `xybpcsmjjcnkjwfsuder`
**Date (UTC):** 2026-07-29
**Action:** Deploy `ai-scan` Edge Function + execute `0048` migration. No new staging, no project switch.

---

## Human Confirmation (unblock)

Per explicit human confirmation, `xybpcsmjjcnkjwfsuder` is the current Cardrealm **Beta** environment, and execution of the CR-0103-C clean deployment package is authorized. This lifts the BLOCKED state recorded in `TASK_CR0103_DEPLOY_REPORT.md`.

- Supabase Project Ref: `xybpcsmjjcnkjwfsuder` ✅ confirmed Beta
- Allowed: (1) `ai-scan` Edge Function deploy (2) `0048_profiles_rls_security_fix.sql` migration

---

## Phase 1 — Deploy `ai-scan` Edge Function

- **Deployed from:** `release/cr0103-deploy/supabase/functions/ai-scan/index.ts`
  - SHA256 (verified pre-deploy): `30bc00d2b61641dd9039eaaa0c3d7cab1eca8fab384edb7c2789bd462aa74c31`
- **Command:** `supabase functions deploy ai-scan --project-ref xybpcsmjjcnkjwfsuder --use-api`
  - `SUPABASE_ACCESS_TOKEN` supplied via env var (not written to repo).
  - **No `--no-verify-jwt`** used → JWT verification boundary preserved.
- **Record:**
  - Function Name: `ai-scan`
  - Version: **22**
  - Status: **ACTIVE**
  - verify_jwt: **true**
  - Deploy Time: `2026-07-29T15:32:59.311Z` → `2026-07-29T15:33:06.649Z` (≈ 7.3s)
  - Existing secrets: **untouched** (deploy uploads code only; no `supabase secrets set` executed)

---

## Phase 2 — Execute Migration `0048`

- **Executed:** `release/cr0103-deploy/supabase/migrations/0048_profiles_rls_security_fix.sql`
  - SHA256 (verified pre-deploy): `9fc5db9b2bf68924dc60e9a1451ac8e8b707645e6a5527305c36f912564a223d`
- **Target confirmation:** SQL executed via Management API scoped to project `xybpcsmjjcnkjwfsuder` (`current_database() = postgres`). No other migration executed; SQL not modified; no merge.
- **Result:** **SUCCESS** (Management API `/database/query` → HTTP 201, no error)
- **Time:** `2026-07-29T15:34:01.548Z` → `2026-07-29T15:34:02.707Z` (≈ 1.16s)

### Before / After (profiles table)

| Aspect | Before | After (0048) |
|---|---|---|
| RLS enabled | true | true |
| Policies | 4 (incl. legacy "Allow all") | `profiles_select_own`, `profiles_update_own` (2) |
| anon grants | 7 (SELECT/INSERT/UPDATE/DELETE/…) | 3 non-data only: `REFERENCES`, `TRIGGER`, `TRUNCATE` |
| authenticated grants | — | `SELECT` + `UPDATE(username,avatar_url)` + `REFERENCES/TRIGGER/TRUNCATE` |

`anon` no longer holds `SELECT/INSERT/UPDATE/DELETE` on `profiles`. The two new policies enforce `auth.uid() = id` for both SELECT and UPDATE (UPDATE limited to `username`, `avatar_url`).

---

## Phase 3 — Basic Verification

### 1. ai-scan Function ACTIVE
Management API `GET /functions/ai-scan` → `status: "ACTIVE"`, `version: 22`, `verify_jwt: true`. ✅

### 2. No Authorization → Expected 401
`GET /functions/v1/ai-scan` (no `Authorization` header) → **HTTP 401**. ✅

### 3. Invalid JWT → Expected 401
- Garbage token `Bearer not.a.real.jwt.token` → **HTTP 401**. ✅
- Well-formed but forged JWT (`sub=ffff...`, invalid signature) → **HTTP 401**. ✅

### 4. profiles RLS

| Check | Result |
|---|---|
| anon access (DB) | **REJECTED** — `SET ROLE anon; SELECT` → `permission denied` (insufficient_privilege) |
| anon access (REST API) | **401** — `GET /rest/v1/profiles` with anon key, no user JWT |
| anon, no headers at all | **401** |
| authenticated: own profile | **allowed** (row count = 1) |
| authenticated: other user | **denied** (row count = 0) |
| authenticated: update own `role` | **denied** (insufficient_privilege) |
| admin: `require_admin()` boundary + own profile | **OK** |

A corrected RLS verification (5 cases) executed cleanly via the database (HTTP 201, no `RAISE EXCEPTION`), confirming all sub-checks pass.

---

## Risk Notes

1. **Bundled test SQL mismatch (non-blocking).** The package's `tests/cr0102_profiles_rls_test.sql` Case 1 assumes `anon` still holds `SELECT` and expects 0 rows via RLS. Final `0048` **revokes `SELECT` from `anon`**, so Case 1 errors with `permission denied` instead of returning 0 rows. The security goal (anon rejected) is met. Verification was performed with an equivalent corrected script (expects `insufficient_privilege` for anon). **Recommend updating the bundled test SQL Case 1** to expect rejection rather than 0 rows.
2. **Repo / deployed drift.** The main repo `supabase/functions/ai-scan/index.ts` (SHA256 `83fb5ec6…`) differs from the deployed package version (`30bc00d2…`). The live function reflects the deploy-package version. **Recommend syncing the repo source to the verified package** before the next deploy to avoid silent drift.
3. **Environment identity.** Historical memory labels `xybpcsmjjcnkjwfsuder` as "production"; per this task's human confirmation it is the **Beta** environment. Deploy executed only under that explicit confirmation. No new staging created, no project switch.

---

## Deployment Package Integrity

All 5 files in `release/cr0103-deploy/` matched `SHA256SUMS.txt` before deployment:
- `DEPLOYMENT_INSTRUCTIONS.md` ✅
- `rollback/0048_profiles_rls_security_fix_rollback.sql` ✅
- `supabase/functions/ai-scan/index.ts` ✅
- `supabase/migrations/0048_profiles_rls_security_fix.sql` ✅
- `tests/cr0102_profiles_rls_test.sql` ✅

---

## Actions Taken / Not Taken

- Deployed `ai-scan` (v22, ACTIVE, verify_jwt=true) ✅
- Executed `0048` migration ✅
- Verified all Phase 3 checks ✅
- Did **not** modify `index.ts` content, Gemini config, or business logic
- Did **not** execute any other migration or modify SQL
- Did **not** roll back; did **not** push to remote
- Git: committed verification report only; tagged (see below)

---

## Git

- Commit: `CR-0103-G Beta Deployment Verification` (report file only; no code changes)
- Tag: `v0.9.14-beta-deployment-verified`
- Push: **not performed** (per task constraint)
