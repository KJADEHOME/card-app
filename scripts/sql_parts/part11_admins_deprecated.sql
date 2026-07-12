-- ============================================
-- Part 11: Mark admins table as deprecated (read-only)
-- ============================================

COMMENT ON TABLE public.admins IS
    'DEPRECATED (SH-003C Phase 1): Migrated to profiles.role. This table is retained read-only for historical audit. Do NOT authenticate through this table.';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_tables
        WHERE schemaname = 'public' AND tablename = 'admins' AND rowsecurity = true
    ) THEN
        ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
    END IF;
END;
$$;

DROP POLICY IF EXISTS "admins_select_all_authenticated" ON public.admins;
CREATE POLICY "admins_select_all_authenticated" ON public.admins
    FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "admins_deny_insert" ON public.admins;
CREATE POLICY "admins_deny_insert" ON public.admins
    FOR INSERT TO authenticated WITH CHECK (false);

DROP POLICY IF EXISTS "admins_deny_update" ON public.admins;
CREATE POLICY "admins_deny_update" ON public.admins
    FOR UPDATE TO authenticated USING (false) WITH CHECK (false);

DROP POLICY IF EXISTS "admins_deny_delete" ON public.admins;
CREATE POLICY "admins_deny_delete" ON public.admins
    FOR DELETE TO authenticated USING (false);

COMMENT ON POLICY "admins_select_all_authenticated" ON public.admins IS 'SH-003C: Backward compat — old admin pages can still read.';
COMMENT ON POLICY "admins_deny_insert" ON public.admins IS 'SH-003C: Deprecated — no frontend writes.';
COMMENT ON POLICY "admins_deny_update" ON public.admins IS 'SH-003C: Deprecated — no frontend writes.';
COMMENT ON POLICY "admins_deny_delete" ON public.admins IS 'SH-003C: Deprecated — no frontend writes.';
