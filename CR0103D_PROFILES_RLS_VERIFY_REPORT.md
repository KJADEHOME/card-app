# CR-0103-D Profiles RLS Online Verification

Verification time: 2026-07-29 23:01:01 +08:00
Status: **BLOCKED — 0048 NOT EFFECTIVE REMOTELY**

## Migration evidence

- Local migration: 0048_profiles_rls_security_fix.sql exists.
- Git: tracked since commit 46ad056.
- Remote migration ledger/status: unavailable.
- Behavioral result: incompatible with 0048.
- Migration execution in this task: none.

## Cases

| Case | Expected | Response | Result |
|---|---|---|---|
| Anonymous profiles query | denied or zero rows | HTTP 200, 3 rows | FAIL P1 |
| User A reads user B | denied | NOT RUN after prerequisite failure | BLOCKED |
| User A reads own profile | one own row | NOT RUN; no staging fixture/token | BLOCKED |
| User A updates role | denied | NOT RUN; no staging write authorized | BLOCKED |
| Admin through require_admin | success | NOT RUN; no staging admin fixture/token | BLOCKED |

No database write or policy change was performed.