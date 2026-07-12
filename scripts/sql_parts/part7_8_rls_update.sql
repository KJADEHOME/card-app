-- ============================================
-- Part 7: Harden profiles UPDATE RLS
-- ============================================

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;

CREATE POLICY "profiles_update_own" ON public.profiles
    FOR UPDATE
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

COMMENT ON POLICY "profiles_update_own" ON public.profiles IS
    'SH-003C: Users can update own profile. Sensitive fields protected by trigger trg_protect_sensitive_profile.';

-- ============================================
-- Part 8: update_my_profile() — controlled self-service update
-- ============================================

CREATE OR REPLACE FUNCTION public.update_my_profile(
    p_username   TEXT DEFAULT NULL,
    p_avatar_url TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_count INTEGER;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
    END IF;

    IF p_username IS NOT NULL THEN
        p_username := LEFT(BTRIM(p_username), 50);
        IF p_username = '' THEN
            RETURN jsonb_build_object('success', false, 'error', 'Username cannot be empty');
        END IF;

        SELECT COUNT(*) INTO v_count
        FROM public.profiles
        WHERE username = p_username AND id != v_uid;

        IF v_count > 0 THEN
            RETURN jsonb_build_object('success', false, 'error', 'Username already taken');
        END IF;

        UPDATE public.profiles SET username = p_username, updated_at = NOW() WHERE id = v_uid;
    END IF;

    IF p_avatar_url IS NOT NULL THEN
        p_avatar_url := LEFT(BTRIM(p_avatar_url), 500);
        UPDATE public.profiles SET avatar_url = p_avatar_url, updated_at = NOW() WHERE id = v_uid;
    END IF;

    RETURN jsonb_build_object('success', true);
END;
$$;

REVOKE ALL ON FUNCTION public.update_my_profile(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_my_profile(TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.update_my_profile(TEXT, TEXT) TO authenticated;

COMMENT ON FUNCTION public.update_my_profile(TEXT, TEXT) IS
    'SH-003C: Controlled self-service profile update. Only whitelisted fields (username, avatar_url). Sensitive fields are NOT accepted.';
