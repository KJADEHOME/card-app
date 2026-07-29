# T1 Card Asset Model

Task: TASK-CR-0099-A  
Model: T1 Genesis Collector  
Status: design only

## Target experience

```text
User buys T1 product
  -> scans a physical card
  -> authenticated AI recognition
  -> approved T1 checklist match
  -> existing collection record
  -> existing portfolio valuation
  -> T1 Genesis Collector progress
```

Example display:

```text
T1 Genesis Collector
T1 Homeground
Collector Progress
12/50 Cards
```

## Capability assessment

| Capability | Existing evidence | Assessment |
|---|---|---|
| Product purchase | platform product/pre-order/order structures | Partial; live purchase/payment not validated |
| Card scan | risk control and `ai-scan` flow | Partial; live Gemini/Edge E2E not validated |
| Collection entry | `complete_card_entry` / `user_collections` architecture | Supported by design; live write not validated |
| Asset valuation | `portfolio_items`, `user_portfolio`, market-price triggers | Supported by migration design; live trigger chain not validated |
| 12/50 progress | Can be derived from checklist matches | Design ready; no new schema proposed |

## Logical model

- `T1 Series`: Homeground 2026 or Dual Dynasty 2026.
- `Checklist Item`: immutable series/card number and approved metadata.
- `User Ownership`: existing authenticated collection record associated with the checklist key.
- `Collector Progress`: distinct owned checklist items divided by 50; duplicates do not increase numerator.
- `Portfolio Value`: existing portfolio valuation only; collector completion is not a price input.

## Governance rules

1. Purchase does not prove possession of every card inside a sealed box.
2. Scan recognition does not prove authenticity; display recognition confidence and verification state separately.
3. Collector badges and progress do not grant market, admin, payment or ownership permissions.
4. Manual correction requires authenticated ownership and audit evidence.
5. No new database structure or production write is authorized by this model.

## Release gap

The model is implementable on top of existing concepts, but Beta launch remains blocked until the approved T1 checklist mapping and one authenticated staging E2E prove scan -> collection -> portfolio -> progress without changing the price or payment state machines.

