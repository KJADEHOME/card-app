-- ============================================================================
-- CR-0107-03A-1: Restore owner-scoped RLS policies (Batch 1)
-- Tables: sms_codes (P0), messages (P1), favorites (P1)
-- Author: WorkBuddy  (plan: CR0107_03A_RLS_EXPOSURE_FIX_PLAN.md)
-- Date: 2026-08-04
--
-- Scope
--   1. sms_codes -> drop public policy "System can manage sms_codes",
--                   ENABLE RLS, add explicit service_role-only policy.
--   2. messages  -> drop orphan "msg_all", restore owner-scoped policies.
--   3. favorites -> drop orphan "fav_all", restore owner-scoped policies.
--
-- Idempotency: every DROP uses IF EXISTS; ENABLE RLS is a no-op if already
--              enabled. The file is safe to re-run.
--
-- Status: STAGED, NOT DEPLOYED. Intended for CEO-approved `supabase db push`.
-- Local syntax validated via pgsql-parser (libpg_query). A full behavioural
-- apply test requires a local Supabase stack (Docker), which is unavailable in
-- the build sandbox; the apply will be validated at deploy time.
-- ============================================================================

-- ----------------------------- sms_codes (P0) -----------------------------
-- Remove the permissive public policy that allowed anon/authenticated to read
-- SMS verification codes (account-takeover risk).
DROP POLICY IF EXISTS "System can manage sms_codes" ON public.sms_codes;

-- Default-deny for anon/authenticated once the public policy is gone.
ALTER TABLE public.sms_codes ENABLE ROW LEVEL SECURITY;

-- Explicit declaration: only service_role may touch this table.
-- (service_role already bypasses RLS; this documents intent and guarantees
--  there is no anon/authenticated access path.)
DROP POLICY IF EXISTS "sms_codes_service_role_only" ON public.sms_codes;
CREATE POLICY "sms_codes_service_role_only"
  ON public.sms_codes
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ----------------------------- messages (P1) ------------------------------
DROP POLICY IF EXISTS "msg_all" ON public.messages;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Messages visible to sender or receiver" ON public.messages;
CREATE POLICY "Messages visible to sender or receiver"
  ON public.messages FOR SELECT
  USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

DROP POLICY IF EXISTS "Users can send messages" ON public.messages;
CREATE POLICY "Users can send messages"
  ON public.messages FOR INSERT
  WITH CHECK (auth.uid() = sender_id);

DROP POLICY IF EXISTS "Users can update own messages" ON public.messages;
CREATE POLICY "Users can update own messages"
  ON public.messages FOR UPDATE
  USING (auth.uid() = sender_id);

-- ----------------------------- favorites (P1) -----------------------------
DROP POLICY IF EXISTS "fav_all" ON public.favorites;
ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Favorites are viewable by owner" ON public.favorites;
CREATE POLICY "Favorites are viewable by owner"
  ON public.favorites FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own favorites" ON public.favorites;
CREATE POLICY "Users can insert own favorites"
  ON public.favorites FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own favorites" ON public.favorites;
CREATE POLICY "Users can delete own favorites"
  ON public.favorites FOR DELETE
  USING (auth.uid() = user_id);
