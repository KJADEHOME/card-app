# T1 Product Import Plan

Task: TASK-CR-0099-A  
Status: design only; no schema or production data changes

## Product catalog proposal

| Field | T1 Homeground 2026 | T1 Dual Dynasty 2026 |
|---|---|---|
| brand | T1 | T1 |
| category | Esports Trading Card | Esports Trading Card |
| edition | Limited 5000 Boxes | Limited 5000 Boxes |
| release_year | 2026 | 2026 |
| lifecycle | draft -> review -> approved -> published | draft -> review -> approved -> published |

Use existing product/platform-card capabilities and map these values only to fields confirmed by the canonical production schema. Do not add columns in CR-0099.

## Import procedure

1. Business owner supplies an approved SKU manifest, localized names, box/card images, rights evidence, price, inventory and release window.
2. Data steward validates required fields, uniqueness, image rights, 5,000-box edition totals and SKU/card numbering.
3. Import first into a non-production fixture or staging project.
4. Run duplicate, stock, price, RLS and admin-authorization checks.
5. Human release owner approves the import batch and audit evidence.
6. Production import uses the existing controlled admin publishing path; no direct browser database writes.

## Card series planning

- Define 50-card collector checklist per series before import.
- Stable card key: approved series code + card number; examples `HG26-001` and `DD26-001`.
- Record athlete/team subject, rarity, parallel, language, image rights, checklist number and box odds in the approved manifest.
- Treat serial-numbered physical cards and the 5,000-box edition as separate concepts.
- Keep T1 Homeground and T1 Dual Dynasty as separate series even when subjects overlap.

## Collection binding

After an authenticated scan, map the recognized result to an approved series/card key, then use the existing card-entry/collection flow. A user owns a collection record; collector progress is a read model derived from distinct owned checklist keys. Low-confidence or ambiguous recognition must require manual confirmation and must not silently bind to a T1 asset.

## Controls and rollback

- Dry-run output lists inserts, updates, duplicates and rejects before any write.
- Import is idempotent by approved stable key.
- Failed rows are quarantined; no partial silent success.
- Rollback is batch-scoped and preserves financial/order history.
- No import proceeds until production migration status and T1 rights/data approval are cleared.

