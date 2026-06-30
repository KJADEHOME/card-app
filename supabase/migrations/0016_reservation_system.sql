-- ============================================================
-- CardRealm MVP Phase 6.5: 预约购买系统（无支付版）
-- ============================================================

-- ============================================================
-- 一、预约表
-- ============================================================
CREATE TABLE IF NOT EXISTS public.reservations (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
    quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','notified','converted','cancelled')),
    source TEXT NOT NULL DEFAULT 'shop' CHECK (source IN ('shop','tiktok','live')),
    notes TEXT DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, product_id, status)
);
-- UNIQUE 约束说明：同一用户对同一商品，同一状态下仅一条记录
-- 这样用户不会重复预约 pending，但如果被 notifed/converted 后可再预约

CREATE INDEX IF NOT EXISTS idx_res_user ON public.reservations(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_res_product ON public.reservations(product_id, status);
CREATE INDEX IF NOT EXISTS idx_res_status ON public.reservations(status);
CREATE INDEX IF NOT EXISTS idx_res_source ON public.reservations(source, created_at DESC);

ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "res_select_owner" ON public.reservations;
DROP POLICY IF EXISTS "res_insert_auth" ON public.reservations;
DROP POLICY IF EXISTS "res_update_owner" ON public.reservations;
CREATE POLICY "res_select_owner" ON public.reservations FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "res_insert_auth" ON public.reservations FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "res_update_owner" ON public.reservations FOR UPDATE USING (auth.uid() = user_id);

-- ============================================================
-- 二、RPC: 创建预约
-- ============================================================
CREATE OR REPLACE FUNCTION create_reservation(
    p_user_id UUID,
    p_product_id UUID,
    p_quantity INTEGER DEFAULT 1,
    p_source TEXT DEFAULT 'shop',
    p_notes TEXT DEFAULT ''
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_product public.products%ROWTYPE;
    v_existing_id UUID;
    v_reservation public.reservations%ROWTYPE;
    v_total_reserved INTEGER;
BEGIN
    -- 检查商品存在且 active
    SELECT * INTO v_product FROM public.products WHERE id = p_product_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '商品不存在');
    END IF;
    IF v_product.status != 'active' THEN
        RETURN jsonb_build_object('success', false, 'error', '商品已下架');
    END IF;

    -- 检查是否已有 pending 预约
    SELECT id INTO v_existing_id FROM public.reservations
    WHERE user_id = p_user_id AND product_id = p_product_id AND status = 'pending';
    IF FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '您已预约过该商品，请等待通知');
    END IF;

    -- 计算当前总预约数
    SELECT COALESCE(SUM(quantity), 0) INTO v_total_reserved
    FROM public.reservations WHERE product_id = p_product_id AND status = 'pending';

    -- 写入预约
    INSERT INTO public.reservations (user_id, product_id, quantity, status, source, notes)
    VALUES (p_user_id, p_product_id, p_quantity, 'pending', p_source, p_notes)
    RETURNING * INTO v_reservation;

    RETURN jsonb_build_object(
        'success', true,
        'reservation_id', v_reservation.id,
        'total_reserved', v_total_reserved + p_quantity,
        'product_stock', v_product.stock,
        'product_title', v_product.title,
        'message', CASE
            WHEN v_product.stock > 0 THEN
                '已加入预约名单，库存恢复时将通知你'
            ELSE
                '已加入等待名单，补货后将通知你'
        END
    );
END;
$$;

-- ============================================================
-- 三、RPC: 获取用户预约列表
-- ============================================================
CREATE OR REPLACE FUNCTION get_user_reservations(
    p_user_id UUID,
    p_status TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', r.id,
            'product_id', r.product_id,
            'quantity', r.quantity,
            'status', r.status,
            'source', r.source,
            'notes', r.notes,
            'created_at', r.created_at,
            'product_title', p.title,
            'product_price', p.price,
            'product_stock', p.stock,
            'product_image', p.image_url,
            'product_category', p.category,
            'product_tags', p.tags,
            'product_source', p.source
        ) ORDER BY r.created_at DESC
    ), '[]'::jsonb) INTO v_result
    FROM public.reservations r
    JOIN public.products p ON r.product_id = p.id
    WHERE r.user_id = p_user_id
      AND (p_status IS NULL OR r.status = p_status);

    RETURN jsonb_build_object(
        'success', true,
        'reservations', v_result,
        'count', jsonb_array_length(v_result)
    );
END;
$$;

-- ============================================================
-- 四、RPC: 取消预约
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_reservation(
    p_reservation_id UUID,
    p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_reservation public.reservations%ROWTYPE;
BEGIN
    SELECT * INTO v_reservation FROM public.reservations
    WHERE id = p_reservation_id AND user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', '预约记录不存在');
    END IF;

    IF v_reservation.status != 'pending' THEN
        RETURN jsonb_build_object('success', false, 'error', '仅可取消等待中的预约');
    END IF;

    UPDATE public.reservations
    SET status = 'cancelled', updated_at = NOW()
    WHERE id = p_reservation_id;

    RETURN jsonb_build_object('success', true, 'message', '已取消预约');
END;
$$;

-- ============================================================
-- 五、RPC: 获取商品预约统计
-- ============================================================
CREATE OR REPLACE FUNCTION get_product_reservation_stats(
    p_product_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_pending INTEGER;
    v_total_reserved INTEGER;
    v_tiktok_reserved INTEGER;
    v_live_reserved INTEGER;
BEGIN
    SELECT COALESCE(SUM(quantity), 0) INTO v_pending
    FROM public.reservations WHERE product_id = p_product_id AND status = 'pending';

    SELECT COALESCE(SUM(quantity), 0) INTO v_total_reserved
    FROM public.reservations WHERE product_id = p_product_id;

    SELECT COALESCE(SUM(quantity), 0) INTO v_tiktok_reserved
    FROM public.reservations WHERE product_id = p_product_id AND source = 'tiktok';

    SELECT COALESCE(SUM(quantity), 0) INTO v_live_reserved
    FROM public.reservations WHERE product_id = p_product_id AND source = 'live';

    RETURN jsonb_build_object(
        'pending', v_pending,
        'total', v_total_reserved,
        'tiktok', v_tiktok_reserved,
        'live', v_live_reserved
    );
END;
$$;

-- ============================================================
-- 六、RPC: 批量获取所有 active 商品的预约统计（shop页面用）
-- ============================================================
CREATE OR REPLACE FUNCTION get_product_reservation_stats_all()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT COALESCE(jsonb_object_agg(
        product_id::TEXT,
        jsonb_build_object(
            'pending', pending_cnt,
            'total', total_cnt
        )
    ), '{}'::jsonb) INTO v_result
    FROM (
        SELECT
            r.product_id,
            COALESCE(SUM(r.quantity) FILTER (WHERE r.status = 'pending'), 0) AS pending_cnt,
            COALESCE(SUM(r.quantity), 0) AS total_cnt
        FROM public.reservations r
        JOIN public.products p ON r.product_id = p.id
        WHERE p.status = 'active'
        GROUP BY r.product_id
    ) sub;

    RETURN jsonb_build_object('success', true, 'stats', v_result);
END;
$$;

-- ============================================================
-- 七、RPC: 获取直播预约转化概览（运营视角）
-- ============================================================
CREATE OR REPLACE FUNCTION get_live_reservation_overview()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'product_id', r.product_id,
            'product_title', p.title,
            'pending_count', SUM(r.quantity) FILTER (WHERE r.status = 'pending'),
            'converted_count', SUM(r.quantity) FILTER (WHERE r.status = 'converted'),
            'total_count', SUM(r.quantity),
            'source', r.source
        ) ORDER BY SUM(r.quantity) DESC
    ), '[]'::jsonb) INTO v_result
    FROM public.reservations r
    JOIN public.products p ON r.product_id = p.id
    WHERE r.source IN ('tiktok', 'live')
    GROUP BY r.product_id, p.title, r.source
    LIMIT 50;

    RETURN jsonb_build_object('success', true, 'data', v_result);
END;
$$;
