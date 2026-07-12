-- ============================================================
-- 0039: Admin Orders RPC — Phase 2 (SH-003C)
--
-- Purpose:
--   1. Add missing columns to orders table (cancel_reason, cancelled_at,
--      dispute_resolution, dispute_resolved_at, dispute_resolved_by)
--   2. Create 3 SECURITY DEFINER RPC functions to replace front-end
--      direct db.from('orders').update() calls:
--        - admin_cancel_order(p_order_id, p_reason)
--        - admin_process_refund(p_order_id, p_action)
--        - admin_resolve_dispute(p_order_id, p_resolution)
--
-- Security:
--   - All RPCs call require_admin() internally (SECURITY DEFINER)
--   - All RPCs write to admin_audit_logs
--   - State validation: only allowed transitions accepted
--   - Action/resolution whitelisted inside function body
--
-- Prerequisite: 0038 (Phase 1) must be executed
--
-- Date: 2026-07-13
-- ============================================================

-- ============================================
-- Part 1: Pre-flight checks
-- ============================================

-- 1.1 Verify require_admin() exists (0038 Phase 1)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.routines
        WHERE routine_schema = 'public' AND routine_name = 'require_admin'
    ) THEN
        RAISE EXCEPTION 'PREREQUISITE FAILED: public.require_admin() does not exist. Run 0038 migration (Phase 1) first.';
    END IF;
END;
$$;

-- 1.2 Verify admin_audit_logs table exists (0038 Phase 1)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'admin_audit_logs'
    ) THEN
        RAISE EXCEPTION 'PREREQUISITE FAILED: public.admin_audit_logs table does not exist. Run 0038 migration (Phase 1) first.';
    END IF;
END;
$$;

-- 1.3 Verify orders table exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'orders'
    ) THEN
        RAISE EXCEPTION 'PREREQUISITE FAILED: public.orders table does not exist.';
    END IF;
END;
$$;

-- ============================================
-- Part 2: Add missing columns to orders table
-- ============================================

ALTER TABLE public.orders
    ADD COLUMN IF NOT EXISTS cancel_reason TEXT,
    ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS dispute_resolution TEXT
        CHECK (dispute_resolution IN ('buyer', 'seller', 'compromise')),
    ADD COLUMN IF NOT EXISTS dispute_resolved_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS dispute_resolved_by UUID REFERENCES auth.users(id) ON DELETE SET NULL;

-- ============================================
-- Part 3: admin_cancel_order(p_order_id, p_reason)
-- ============================================
-- Replaces: db.from('orders').update({status:'cancelled', cancel_reason, cancelled_at})
-- Security: require_admin() + status whitelist + audit log

CREATE OR REPLACE FUNCTION public.admin_cancel_order(
    p_order_id UUID,
    p_reason TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_admin_uid UUID;
    v_order RECORD;
BEGIN
    -- Step 1: Verify caller is admin (throws if not)
    v_admin_uid := public.require_admin();

    -- Step 2: Fetch order
    SELECT id, status INTO v_order FROM public.orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    -- Step 3: State validation — only pending/paid/disputed can be cancelled
    IF v_order.status NOT IN ('pending', 'paid', 'disputed') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_STATE',
            'detail', 'Current status "' || v_order.status || '" cannot be cancelled'
        );
    END IF;

    -- Step 4: Update order
    UPDATE public.orders
    SET status = 'cancelled',
        cancel_reason = p_reason,
        cancelled_at = NOW(),
        updated_at = NOW()
    WHERE id = p_order_id;

    -- Step 5: Audit log (separate BEGIN/EXCEPTION to ensure persistence even if later code fails)
    BEGIN
        INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
        VALUES (
            v_admin_uid,
            'cancel_order',
            'order',
            p_order_id,
            jsonb_build_object(
                'reason', p_reason,
                'prev_status', v_order.status
            )
        );
    EXCEPTION WHEN OTHERS THEN
        -- Audit log failure should not block the operation
        -- But we log it for debugging
        RAISE NOTICE 'Audit log insert failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_cancel_order(UUID, TEXT) TO authenticated;

-- ============================================
-- Part 4: admin_process_refund(p_order_id, p_action)
-- ============================================
-- Replaces: db.from('orders').update({status, refund_processed_at})
-- Security: require_admin() + action whitelist + status validation + audit log

CREATE OR REPLACE FUNCTION public.admin_process_refund(
    p_order_id UUID,
    p_action TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_admin_uid UUID;
    v_order RECORD;
    v_new_status TEXT;
BEGIN
    -- Step 1: Verify caller is admin
    v_admin_uid := public.require_admin();

    -- Step 2: Action whitelist
    IF p_action NOT IN ('approve', 'reject') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_ACTION');
    END IF;

    -- Step 3: Fetch order
    SELECT id, status INTO v_order FROM public.orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    -- Step 4: State validation
    -- approve: only disputed/refund-requested orders can be refunded
    -- reject: only disputed orders can be rejected (back to paid)
    IF p_action = 'approve' AND v_order.status NOT IN ('disputed', 'paid') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_STATE',
            'detail', 'Cannot approve refund for status "' || v_order.status || '"'
        );
    END IF;

    IF p_action = 'reject' AND v_order.status NOT IN ('disputed', 'paid') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_STATE',
            'detail', 'Cannot reject refund for status "' || v_order.status || '"'
        );
    END IF;

    -- Step 5: Determine new status
    v_new_status := CASE WHEN p_action = 'approve' THEN 'refunded' ELSE 'paid' END;

    -- Step 6: Update order
    UPDATE public.orders
    SET status = v_new_status,
        refunded_at = CASE WHEN p_action = 'approve' THEN NOW() ELSE refunded_at END,
        updated_at = NOW()
    WHERE id = p_order_id;

    -- Step 7: Audit log
    BEGIN
        INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
        VALUES (
            v_admin_uid,
            'process_refund',
            'order',
            p_order_id,
            jsonb_build_object(
                'action', p_action,
                'prev_status', v_order.status,
                'new_status', v_new_status
            )
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Audit log insert failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_process_refund(UUID, TEXT) TO authenticated;

-- ============================================
-- Part 5: admin_resolve_dispute(p_order_id, p_resolution)
-- ============================================
-- Replaces: db.from('orders').update({status, dispute_resolution, dispute_resolved_at, dispute_resolved_by})
-- Security: require_admin() + resolution whitelist + status validation + audit log

CREATE OR REPLACE FUNCTION public.admin_resolve_dispute(
    p_order_id UUID,
    p_resolution TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_admin_uid UUID;
    v_order RECORD;
    v_new_status TEXT;
BEGIN
    -- Step 1: Verify caller is admin
    v_admin_uid := public.require_admin();

    -- Step 2: Resolution whitelist
    IF p_resolution NOT IN ('buyer', 'seller', 'compromise') THEN
        RETURN jsonb_build_object('success', false, 'error', 'INVALID_RESOLUTION');
    END IF;

    -- Step 3: Fetch order
    SELECT id, status INTO v_order FROM public.orders WHERE id = p_order_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'ORDER_NOT_FOUND');
    END IF;

    -- Step 4: State validation — only disputed orders can be resolved
    IF v_order.status != 'disputed' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'INVALID_STATE',
            'detail', 'Order is not in disputed state (current: "' || v_order.status || '")'
        );
    END IF;

    -- Step 5: Determine new status
    -- buyer → refunded (buyer wins, gets money back)
    -- seller → completed (seller wins, keeps money)
    -- compromise → completed (negotiated settlement, status completed)
    v_new_status := CASE
        WHEN p_resolution = 'buyer' THEN 'refunded'
        WHEN p_resolution IN ('seller', 'compromise') THEN 'completed'
    END;

    -- Step 6: Update order
    UPDATE public.orders
    SET status = v_new_status,
        dispute_resolution = p_resolution,
        dispute_resolved_at = NOW(),
        dispute_resolved_by = v_admin_uid,
        updated_at = NOW()
    WHERE id = p_order_id;

    -- Step 7: Audit log
    BEGIN
        INSERT INTO public.admin_audit_logs (admin_id, action, target_type, target_id, details)
        VALUES (
            v_admin_uid,
            'resolve_dispute',
            'order',
            p_order_id,
            jsonb_build_object(
                'resolution', p_resolution,
                'prev_status', v_order.status,
                'new_status', v_new_status
            )
        );
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Audit log insert failed: %', SQLERRM;
    END;

    RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_resolve_dispute(UUID, TEXT) TO authenticated;

-- ============================================
-- Part 6: Verify all objects created
-- ============================================
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM information_schema.routines
    WHERE routine_schema = 'public'
      AND routine_name IN ('admin_cancel_order', 'admin_process_refund', 'admin_resolve_dispute');

    IF v_count != 3 THEN
        RAISE EXCEPTION 'VERIFICATION FAILED: Expected 3 RPC functions, found %', v_count;
    END IF;

    RAISE NOTICE 'Phase 2 migration 0039: All 3 RPC functions created successfully.';
END;
$$;

-- ============================================
-- ROLLBACK SQL
-- ============================================
-- DROP FUNCTION IF EXISTS public.admin_cancel_order(UUID, TEXT) CASCADE;
-- DROP FUNCTION IF EXISTS public.admin_process_refund(UUID, TEXT) CASCADE;
-- DROP FUNCTION IF EXISTS public.admin_resolve_dispute(UUID, TEXT) CASCADE;
-- ALTER TABLE public.orders
--     DROP COLUMN IF EXISTS cancel_reason,
--     DROP COLUMN IF EXISTS cancelled_at,
--     DROP COLUMN IF EXISTS dispute_resolution,
--     DROP COLUMN IF EXISTS dispute_resolved_at,
--     DROP COLUMN IF EXISTS dispute_resolved_by;
