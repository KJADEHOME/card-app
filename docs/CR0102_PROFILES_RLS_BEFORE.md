# CR-0102 Profiles RLS Before-State Audit

Task: TASK-CR-0102-B  
Audit date: 2026-07-29  
Scope: profiles access control only

## Observed production behavior

CR-0101 issued an anonymous REST request selecting only profile IDs. The request returned HTTP 200 with three rows. This confirms that anonymous access can satisfy at least one current profiles SELECT policy.

## Local migration evidence

| Operation | Policy evidence | Effective intent/risk |
|---|---|---|
| SELECT | 0036 creates `Users can view all profiles` with `USING (true)` and no role restriction | Anonymous and authenticated requests can read every profile row allowed by table grants; confirmed vulnerable remotely |
| INSERT | 0036 creates `Users can insert own profile` with `auth.uid() = id` | Authenticated owner insert; used as compatibility protection for profile synchronization |
| UPDATE | 0036 creates `Users can update own profile`; 0038 drops it and creates `profiles_update_own` with owner checks | Row ownership is restricted, while 0038/0042 trigger protects sensitive fields |
| DELETE | 0036 creates `Users can delete own profile` | Authenticated owner deletion remains possible; not required by the CR-0102 target model |

## Sensitive update controls already present

- `protect_sensitive_profile_fields()` and `trg_protect_sensitive_profile` protect role, disablement and merchant-verification fields.
- `update_my_profile(username, avatar_url)` is the existing controlled self-service RPC.
- `require_admin()` and existing SECURITY DEFINER admin RPCs provide the SH-003 administrator boundary.

CR-0102 must not replace or modify those functions. The missing control is a restrictive SELECT policy plus column-level UPDATE privilege.

## Access before fix

| Actor | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| anon | All rows observed | Not intentionally allowed | Not intentionally allowed | Not intentionally allowed |
| authenticated user | All rows | Own row | Own row, trigger-protected | Own row |
| admin browser session | All rows through permissive SELECT | Own row | Own row/direct or controlled RPC | Own row |
| controlled admin RPC | Function-specific access after `require_admin()` | Function-specific | Function-specific | Function-specific |

Risk: **P1 / Beta blocker**.

