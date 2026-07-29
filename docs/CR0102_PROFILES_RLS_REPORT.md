# CR-0102 Profiles RLS Security Report

Task: TASK-CR-0102-B  
Date: 2026-07-29  
Status: **CODE COMPLETE / NOT DEPLOYED**

## 1. Vulnerability cause

Migration 0036 created `Users can view all profiles` with `USING (true)` without restricting the policy to authenticated users. Migration 0038 hardened UPDATE but left the broad SELECT policy intact. CR-0101 confirmed three anonymous profile IDs were returned.

## 2. Fix

- Remove all known broad/overlapping profiles policies.
- Revoke profiles DML privileges from `anon`.
- Allow authenticated SELECT only when `auth.uid() = id`.
- Remove direct authenticated INSERT so callers cannot inject sensitive fields while creating a row; the existing trusted Auth synchronization path remains authoritative.
- Allow authenticated UPDATE only for `username` and `avatar_url`, with owner RLS checks.
- Provide no direct DELETE policy.
- Leave `require_admin()`, SH-003 functions, sensitive-field trigger and business schema unchanged.
- Admin cross-user access remains through existing SECURITY DEFINER RPCs guarded by `require_admin()`.

## 3. Migration number

`0048_profiles_rls_security_fix.sql`.

0045 and 0046 are reserved by the current SH-006 plan, while 0047 is the recommended marketplace gate identity. 0048 avoids overwriting any existing or reserved migration. The registry was not modified in this task and must be reconciled before deployment approval.

## 4. Tests

`tests/cr0102_profiles_rls_test.sql` defines five transactional staging cases:

1. anon reads zero rows;
2. user A cannot read user B;
3. user A reads own profile;
4. user A cannot update role;
5. admin passes unchanged `require_admin()` and reads own profile.

Static validation confirms transaction boundaries, policy removals, anon revocation, owner predicates, no direct authenticated INSERT/DELETE, column-level UPDATE grant and unchanged protected files. The SQL test was **not executed**, because migration execution and production database changes are outside this task. A staging registration regression is mandatory before production deployment.

## 5. Rollback

`0048_profiles_rls_security_fix_rollback.sql` restores the pre-fix policies and table grants. It deliberately restores the vulnerable public SELECT behavior and therefore requires explicit security-owner approval. Preferred recovery is a forward corrective migration rather than rollback.

## Release decision

The P1 issue is fixed in code but remains a Beta blocker until 0048 is reviewed, registered, applied to staging, all five SQL tests and a new-user registration/profile-synchronization regression pass, deployed through an approved production change, and the anonymous endpoint is retested.

