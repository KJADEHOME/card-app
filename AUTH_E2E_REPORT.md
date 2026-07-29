# Cardrealm Auth E2E Report

Status: **BLOCKED / SECURITY FINDING**

## Requested flow

Registration -> login -> profile creation -> persistent session for user, merchant and admin roles.

## Executed

- Supabase Auth health endpoint: PASS, HTTP 200.
- Local registration contract: `auth.signUp()` present.
- Local login contract: `auth.signInWithPassword()` present.
- SH-003 static regressions were previously green and SH-003 code was not modified.
- Anonymous `portfolio_items` and `user_portfolio` queries returned zero rows.
- Anonymous `profiles?select=id&limit=5` returned three rows.

## Not executed

No production account was registered, no session was created and no role was changed. Test credentials, staging designation, cleanup ownership and credential-rotation evidence were unavailable.

## Findings

| Finding | Severity | Beta blocker |
|---|---|---|
| Anonymous profile IDs are readable | P1 | Yes, until intended policy is confirmed or corrected |
| User/merchant/admin live session matrix not executed | P1 | Yes |
| Session persistence and profile trigger not observed | P1 | Yes |

SH-003 authentication architecture remains unchanged. Any RLS correction requires a separate approved security task; this validation did not modify policies.

