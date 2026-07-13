-- 0042_admin_rpc_group_c.sql
-- SH-003C Phase 3 Group C: secure user and merchant management RPCs
BEGIN;

-- Controlled admin RPCs set a transaction-local marker after require_admin().
-- The sensitive-fields trigger only accepts this marker from a SECURITY DEFINER owner context.
CREATE OR REPLACE FUNCTION public.protect_sensitive_profile_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_uid UUID := auth.uid();
    v_role TEXT;
    v_controlled_admin_rpc BOOLEAN := current_setting('cardrealm.controlled_admin_rpc', true) = 'on';
BEGIN
    IF v_uid IS NULL THEN RETURN NEW; END IF;
    SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;

    IF v_role = 'super_admin' THEN RETURN NEW; END IF;
    IF v_controlled_admin_rpc AND v_role IN ('admin','super_admin') THEN RETURN NEW; END IF;

    IF NEW.role IS DISTINCT FROM OLD.role
       OR NEW.is_disabled IS DISTINCT FROM OLD.is_disabled
       OR NEW.disabled_reason IS DISTINCT FROM OLD.disabled_reason
       OR NEW.disabled_at IS DISTINCT FROM OLD.disabled_at
       OR NEW.disabled_by IS DISTINCT FROM OLD.disabled_by
       OR NEW.merchant_verified IS DISTINCT FROM OLD.merchant_verified
       OR NEW.merchant_verified_by IS DISTINCT FROM OLD.merchant_verified_by THEN
        RAISE EXCEPTION 'FORBIDDEN: sensitive profile fields require controlled admin RPC'
            USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_disable_user(p_user_id UUID, p_reason TEXT DEFAULT NULL)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE v_admin_id UUID;
BEGIN
    v_admin_id := public.require_admin();
    IF p_user_id IS NULL OR p_user_id = v_admin_id THEN
        RAISE EXCEPTION 'INVALID: cannot disable this account' USING ERRCODE='22023';
    END IF;
    PERFORM set_config('cardrealm.controlled_admin_rpc','on',true);
    UPDATE public.profiles
       SET is_disabled = TRUE,
           disabled_reason = LEFT(COALESCE(p_reason,''),500),
           disabled_at = NOW(), disabled_by = v_admin_id
     WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND: user'; END IF;
    PERFORM public.log_admin_action('disable_user','user',p_user_id,
        jsonb_build_object('reason',LEFT(COALESCE(p_reason,''),500)));
    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_enable_user(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE v_admin_id UUID;
BEGIN
    v_admin_id := public.require_admin();
    PERFORM set_config('cardrealm.controlled_admin_rpc','on',true);
    UPDATE public.profiles
       SET is_disabled = FALSE, disabled_reason = NULL, disabled_at = NULL, disabled_by = NULL
     WHERE id = p_user_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND: user'; END IF;
    PERFORM public.log_admin_action('enable_user','user',p_user_id,'{}'::jsonb);
    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_verify_merchant(
    p_user_id UUID,
    p_merchant_name TEXT,
    p_merchant_desc TEXT DEFAULT '',
    p_merchant_badge TEXT DEFAULT '✅'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE v_admin_id UUID;
BEGIN
    v_admin_id := public.require_admin();
    IF BTRIM(COALESCE(p_merchant_name,'')) = '' THEN
        RETURN jsonb_build_object('success',false,'error','店铺名称不能为空');
    END IF;
    PERFORM set_config('cardrealm.controlled_admin_rpc','on',true);
    UPDATE public.profiles
       SET role='merchant', merchant_verified=TRUE, merchant_verified_at=NOW(),
           merchant_verified_by=v_admin_id,
           merchant_name=LEFT(BTRIM(p_merchant_name),200),
           merchant_desc=LEFT(COALESCE(p_merchant_desc,''),2000),
           merchant_badge=LEFT(COALESCE(p_merchant_badge,'✅'),50), updated_at=NOW()
     WHERE id=p_user_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','用户不存在'); END IF;
    PERFORM public.log_admin_action('verify_merchant','user',p_user_id,
        jsonb_build_object('merchant_name',LEFT(BTRIM(p_merchant_name),200)));
    RETURN jsonb_build_object('success',true,'user_id',p_user_id,'role','merchant');
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_revoke_merchant(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE v_admin_id UUID;
BEGIN
    v_admin_id := public.require_admin();
    PERFORM set_config('cardrealm.controlled_admin_rpc','on',true);
    UPDATE public.profiles
       SET role='user', merchant_verified=FALSE, merchant_verified_at=NULL,
           merchant_verified_by=NULL, merchant_name=NULL, merchant_desc='', merchant_badge='', updated_at=NOW()
     WHERE id=p_user_id;
    IF NOT FOUND THEN RETURN jsonb_build_object('success',false,'error','用户不存在'); END IF;
    PERFORM public.log_admin_action('revoke_merchant','user',p_user_id,'{}'::jsonb);
    RETURN jsonb_build_object('success',true,'user_id',p_user_id,'role','user');
END;
$$;

REVOKE ALL ON FUNCTION public.admin_disable_user(UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_disable_user(UUID,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_enable_user(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_enable_user(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_verify_merchant(UUID,TEXT,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_verify_merchant(UUID,TEXT,TEXT,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_revoke_merchant(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_revoke_merchant(UUID) TO authenticated;

-- Disable legacy overloads that accepted a frontend-supplied administrator UUID.
REVOKE ALL ON FUNCTION public.admin_verify_merchant(UUID,UUID,TEXT,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_revoke_merchant(UUID,UUID) FROM PUBLIC, anon, authenticated;

COMMIT;
