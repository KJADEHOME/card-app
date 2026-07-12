-- ============================================
-- Part 6: Sensitive field protection trigger
-- ============================================

CREATE OR REPLACE FUNCTION public.protect_sensitive_profile_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid       UUID := auth.uid();
    v_role      TEXT;
BEGIN
    -- If no session user (service_role / migration context), allow
    IF v_uid IS NULL THEN
        RETURN NEW;
    END IF;

    -- Look up caller's role (bypasses RLS via SECURITY DEFINER)
    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;

    -- super_admin can change anything (via set_user_role RPC)
    IF v_role = 'super_admin' THEN
        RETURN NEW;
    END IF;

    -- For everyone else: block changes to sensitive fields
    IF NEW.role IS DISTINCT FROM OLD.role THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify role field' USING ERRCODE = '42501';
    END IF;

    IF NEW.is_disabled IS DISTINCT FROM OLD.is_disabled THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify is_disabled field' USING ERRCODE = '42501';
    END IF;

    IF NEW.disabled_reason IS DISTINCT FROM OLD.disabled_reason THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify disabled_reason field' USING ERRCODE = '42501';
    END IF;

    IF NEW.disabled_at IS DISTINCT FROM OLD.disabled_at THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify disabled_at field' USING ERRCODE = '42501';
    END IF;

    IF NEW.disabled_by IS DISTINCT FROM OLD.disabled_by THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify disabled_by field' USING ERRCODE = '42501';
    END IF;

    IF NEW.merchant_verified IS DISTINCT FROM OLD.merchant_verified THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify merchant_verified field' USING ERRCODE = '42501';
    END IF;

    IF NEW.merchant_verified_by IS DISTINCT FROM OLD.merchant_verified_by THEN
        RAISE EXCEPTION 'FORBIDDEN: Cannot modify merchant_verified_by field' USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_sensitive_profile ON public.profiles;
CREATE TRIGGER trg_protect_sensitive_profile
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_sensitive_profile_fields();

COMMENT ON FUNCTION public.protect_sensitive_profile_fields() IS
    'SH-003C: Trigger function that blocks non-super_admin users from modifying sensitive profile fields (role, is_disabled, disabled_*, merchant_verified*). service_role (auth.uid()=NULL) and super_admin bypass.';
