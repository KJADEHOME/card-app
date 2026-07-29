# Cardrealm Portfolio E2E Report

Status: **BLOCKED**

## Static contract

- `portfolio_items` exists in migration design.
- Canonical fields are `current_price`, `profit_loss`, `profit_percent`, not generic `current_value` and `profit`.
- `user_portfolio` aggregates `total_asset_value`, `total_cost`, `profit_loss`, `profit_percent`.
- Market-price and auto-refresh trigger contracts are present.

## Live cases

| Case | Result |
|---|---|
| New asset | Not run; requires safe authenticated scan/card entry |
| Asset without price | Not run |
| Abnormal price | Not run; price state machine must not be disturbed |
| Anonymous portfolio read | PASS: zero rows returned |

The portfolio flow is blocked upstream by Auth/AI findings and missing isolated test accounts. No collection or portfolio row was created or changed.

