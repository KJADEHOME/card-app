# Cardrealm Beta Business Test Report

Task: TASK-CR-0099-A  
Test date: 2026-07-29  
Method: local static and simulated regression only; no production writes or real payment

## Test execution summary

| Suite | Result |
|---|---|
| SH-003C Phase 1 | PASS, 107/107 |
| SH-003C Phase 3 | PASS, 19/19 |
| SH-006 0044 static safety | PASS, 12/12 |
| AI recognition validation | PASS |
| Authentication security | PASS |
| Trading flow validation | PASS |
| XSS suites | PASS, 314/314 across four suites |

All ten Node.js scripts exited with code 0. These results validate repository logic and guards, not production connectivity.

## AI card recognition flow

Expected path: image upload -> `risk-control.js` -> `ai-scan` Edge Function -> Gemini -> card entry -> portfolio.

| Case | Local result | Release conclusion |
|---|---|---|
| Normal image | Input path and accepted MIME behavior present | BLOCKED pending real authenticated E2E |
| Oversized image | PASS: size rejection guard covered | Static PASS |
| Non-image file | PASS: `MIME_BLOCKED` behavior covered | Static PASS |
| Recognition failure | PASS: error/fallback path covered | Static PASS |
| Unauthorized call | PASS: authorization guard covered | Static PASS |

No Gemini call, Edge Function deployment check, Storage upload, `cards`/collection insert, or portfolio write was performed. The repository architecture uses `complete_card_entry` and `user_collections`; a direct `cards` insert should not be assumed without live schema evidence.

## Collection asset flow

Expected path: scanned card -> collection -> valuation -> portfolio aggregation.

Schema evidence confirms:

- `portfolio_items`: `current_price`, `profit_loss`, `profit_percent`.
- `user_portfolio`: `total_asset_value`, `total_cost`, `profit_loss`, `profit_percent`.
- `0026_portfolio_use_mark_price.sql` refreshes portfolio values from market price.

The requested generic names `current_value` and `profit` are not the canonical field names in the inspected schema. Result: **static PASS / live E2E BLOCKED**.

## Marketplace transaction flow

Expected path: listing -> buyer order -> order record -> payment state -> logistics -> completion.

Local trading-flow validation passed. Existing migration evidence includes row locking, inventory reservation and order/payment fields. No payment state-machine code or SQL was changed.

Result: **static PASS / live E2E BLOCKED** because no seller/buyer test accounts, payment sandbox callback, logistics event, or completion transition was exercised.

## Regression boundary

This task did not change SH-003 authentication, SH-006 database safety, payment state machines, price triggers, AI recognition logic, UI, or production configuration.

