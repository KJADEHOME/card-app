# CR-0103 AI Scan E2E Report

Status: **BLOCKED UPSTREAM**

Requested flow: login -> image upload -> Storage -> ai-scan -> Gemini -> cards -> portfolio.

| Test | Result |
|---|---|
| Normal card image | NOT RUN — deployed auth boundary failed and no staging account |
| Invalid file type | Local validation PASS; no live upload |
| Oversized file | Local validation contract PASS; no live upload |
| Recognition failure | Local fallback/static test PASS; no live Gemini call |
| Frontend error handling | Static AI recognition validation PASS |
| Edge response | Remote no-token response is HTTP 400, expected 401 |
| Cards/portfolio data | No test data created |

No Gemini prompt or recognition logic was changed. A valid image was not sent because it could consume an external API and write to a non-isolated project while the security gate is failing.