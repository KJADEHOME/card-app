# CR-0103 Security Regression Report

Status: **BLOCKED — LOCAL PASS / REMOTE FAIL**

| Case | Expected | Evidence | Result |
|---|---|---|---|
| 1. ai-scan without Authorization | 401 | Remote returned HTTP 400 | FAIL P0 |
| 2. ai-scan with invalid JWT | 401 | Local mock PASS; live deployment parity already failed Case 1 | BLOCKED P0 |
| 3. ai-scan with valid JWT | Continue | Local mock PASS; no staging user token | BLOCKED P1 |
| 4. anon reads profiles | denied or zero rows | Remote HTTP 200 with 3 rows | FAIL P1 |
| 5. user A reads user B | denied | No isolated users; 0048 not deployed | BLOCKED P1 |
| 6. user reads own profile | PASS | No isolated user; 0048 not deployed | BLOCKED P1 |
| 7. ordinary user updates role | denied | Static SH-003 PASS; live write not authorized | BLOCKED P1 |

Local CR-0102-A tests passed 3/3. SH-003 regressions passed 107/107 and 19/19. The remote failures show that source/migration fixes have not reached the tested environment; they do not show a regression in the local fix.