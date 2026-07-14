# SH-006 Phase 1 Deployment — 0044 Financial FK Safety

## Scope

This patch only changes financial-history relationships for:

- `public.escrow_records`
- `public.refunds`
- `public.disputes`

It does not change admin auth, payment state machines, pricing, AI scan, or front-end code.

## Before deployment

1. Confirm migrations `0040`–`0043` are already deployed.
2. Export/backup schema definitions for the three target tables.
3. Run a database backup or Supabase PITR checkpoint if available.
4. Run the static check:

```bash
node tests/test_0044_static.js
```

## Deploy

Run in Supabase SQL Editor or your approved migration runner:

```text
supabase/migrations/0044_financial_fk_safety.sql
```

The migration runs in one transaction and fails closed if required tables/columns are missing.

## Validate

Immediately run:

```text
supabase/migrations/test_0044_financial_fk_safety.sql
```

Expected:

- All 7 FK rows report `PASS`
- All 7 nullable rows report `PASS`
- All orphan counts are `0`
- All missing-snapshot counts are `0`

Then perform application regression:

- Admin can open historical escrow/refund/dispute records
- Current refund/dispute workflows still operate
- Existing payment/escrow RPCs execute normally
- Pages tolerate a deleted/missing related user/order by showing snapshot/fallback data

## Rollback

Use only if validation fails before any parent user/order has been deleted:

```text
supabase/migrations/0044_financial_fk_safety_rollback.sql
```

Rollback refuses to run if any new NULL parent references exist, because destructive CASCADE semantics cannot safely be restored after a deletion.

## Git

Suggested commit/tag:

```bash
git add supabase/migrations/0044_* supabase/migrations/test_0044_financial_fk_safety.sql tests/test_0044_static.js MIGRATION_REGISTRY.md TASK_INDEX.md DEPLOY_SH006_PHASE1.md SH-006_Phase1_Report.md
git commit -m "SH-006 Phase 1: preserve financial records on parent deletion"
git tag v0.9.7-financial-fk-safety
```
