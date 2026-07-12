CREATE OR REPLACE FUNCTION public.require_admin()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid  UUID := auth.uid();
    v_role TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Not authenticated'
            USING ERRCODE = '42501';
    END IF;

    SELECT role INTO v_role
    FROM public.profiles
    WHERE id = v_uid;

    IF v_role IS NULL OR v_role NOT IN ('admin', 'super_admin') THEN
        RAISE EXCEPTION 'FORBIDDEN: Admin access required'
            USING ERRCODE = '42501';
    END IF;

    RETURN v_uid;
END;
$$;

REVOKE ALL ON FUNCTION public.require_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.require_admin() FROM anon;
GRANT EXECUTE ON FUNCTION public.require_admin() TO authenticated;

COMMENT ON FUNCTION public.require_admin() IS
    'SH-003C: Unified admin auth check. SECURITY DEFINER. No parameters — uses auth.uid() only. Returns admin UUID or raises FORBIDDEN.';
