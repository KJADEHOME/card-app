-- ============================================
-- Part 9: set_user_role() — super_admin only role management
-- ============================================

CREATE OR REPLACE FUNCTION public.set_user_role(
    p_target_id UUID,
    p_new_role  TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_caller_uid UUID;
    v_caller_role TEXT;
    v_target_exists BOOLEAN;
    v_old_role TEXT;
    v_log_id UUID;
BEGIN
    -- 1. Verify caller is authenticated
    v_caller_uid := auth.uid();
    IF v_caller_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
    END IF;

    -- 2. Verify caller is super_admin (NOT just admin)
    SELECT role INTO v_caller_role
    FROM public.profiles
    WHERE id = v_caller_uid;

    IF v_caller_role IS NULL OR v_caller_role != 'super_admin' THEN
        -- Log the denied attempt
        BEGIN
            INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
            VALUES (
                v_caller_uid,
                'set_user_role_DENIED',
                'user',
                p_target_id,
                jsonb_build_object('requested_role', p_new_role, 'caller_role', v_caller_role)
            );
        EXCEPTION WHEN OTHERS THEN NULL;
        END;

        RETURN jsonb_build_object('success', false, 'error', 'FORBIDDEN: Only super_admin can change user roles');
    END IF;

    -- 3. Validate new role value
    IF p_new_role NOT IN ('user', 'merchant', 'admin', 'super_admin') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid role value');
    END IF;

    -- 4. Verify target user exists
    SELECT EXISTS(SELECT 1 FROM public.profiles WHERE id = p_target_id) INTO v_target_exists;
    IF NOT v_target_exists THEN
        RETURN jsonb_build_object('success', false, 'error', 'Target user not found');
    END IF;

    -- 5. Get old role for audit
    SELECT role INTO v_old_role FROM public.profiles WHERE id = p_target_id;

    -- 6. Update role (trigger allows this because caller is super_admin)
    UPDATE public.profiles
    SET role = p_new_role, updated_at = NOW()
    WHERE id = p_target_id;

    -- 7. Write audit log
    INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
    VALUES (
        v_caller_uid,
        'set_user_role',
        'user',
        p_target_id,
        jsonb_build_object('old_role', v_old_role, 'new_role', p_new_role)
    )
    RETURNING id INTO v_log_id;

    RETURN jsonb_build_object(
        'success', true,
        'log_id', v_log_id,
        'old_role', v_old_role,
        'new_role', p_new_role
    );
END;
$$;

REVOKE ALL ON FUNCTION public.set_user_role(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_user_role(UUID, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_user_role(UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.set_user_role(UUID, TEXT) IS
    'SH-003C: Super_admin only. Changes a user role. Logs to admin_audit_logs. Denied attempts are also logged.';

-- ============================================
-- Part 10: Set first super_admin (one-time controlled SQL)
-- ============================================

UPDATE public.profiles
SET role = 'super_admin', updated_at = NOW()
WHERE id IN (
    SELECT id FROM auth.users WHERE email = 'admin@cardrealm.top'
)
AND (role IS NULL OR role NOT IN ('super_admin'));
