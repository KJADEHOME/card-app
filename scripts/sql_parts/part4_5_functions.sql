CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid  UUID := auth.uid();
    v_role TEXT;
BEGIN
    IF v_uid IS NULL THEN
        RETURN FALSE;
    END IF;

    SELECT role INTO v_role
    FROM public.profiles
    WHERE id = v_uid;

    RETURN v_role = 'super_admin';
END;
$$;

REVOKE ALL ON FUNCTION public.is_platform_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_platform_admin() FROM anon;
GRANT EXECUTE ON FUNCTION public.is_platform_admin() TO authenticated;

COMMENT ON FUNCTION public.is_platform_admin() IS
    'SH-003C: Returns TRUE if current user has super_admin role. Used for platform-level operations.';

-- ============================================
-- Part 5: log_admin_action()
-- ============================================

CREATE OR REPLACE FUNCTION public.log_admin_action(
    p_action      TEXT,
    p_target_type TEXT,
    p_target_id   UUID DEFAULT NULL,
    p_details     JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_admin_uid UUID;
    v_log_id    UUID;
    v_action    TEXT;
    v_tgt_type  TEXT;
BEGIN
    v_admin_uid := public.require_admin();

    v_action   := LEFT(BTRIM(p_action), 100);
    v_tgt_type := LEFT(BTRIM(p_target_type), 50);

    IF v_action IS NULL OR v_action = '' THEN
        RAISE EXCEPTION 'INVALID: action cannot be empty' USING ERRCODE = '22004';
    END IF;

    IF v_tgt_type IS NULL OR v_tgt_type = '' THEN
        v_tgt_type := 'unknown';
    END IF;

    -- Strip sensitive keys (defense-in-depth, even if caller included them)
    p_details := p_details
        - 'password' - 'password_hash' - 'token' - 'session_token'
        - 'secret' - 'api_key' - 'private_key' - 'signing_key'
        - 'card_number' - 'cvv' - 'stripe_token' - 'payment_intent_id';

    INSERT INTO public.admin_audit_logs (
        admin_id, action, target_type, target_id, details
    )
    VALUES (
        v_admin_uid, v_action, v_tgt_type, p_target_id, p_details
    )
    RETURNING id INTO v_log_id;

    RETURN v_log_id;
END;
$$;

REVOKE ALL ON FUNCTION public.log_admin_action(TEXT, TEXT, UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_admin_action(TEXT, TEXT, UUID, JSONB) FROM anon;
GRANT EXECUTE ON FUNCTION public.log_admin_action(TEXT, TEXT, UUID, JSONB) TO authenticated;

COMMENT ON FUNCTION public.log_admin_action(TEXT, TEXT, UUID, JSONB) IS
    'SH-003C: Controlled audit log writer. Calls require_admin() internally. Strips sensitive keys.';
