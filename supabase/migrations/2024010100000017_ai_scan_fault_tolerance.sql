-- ============================================
-- 0017: AI识卡容错系统 — 三级分类 + 人工确认
-- ============================================
-- 依赖: 0010 (ai_scan_logs), 0008 (scan_history)
-- AI供应商: Google Gemini (已切换)

-- ============================================
-- 1. scan_history 添加分类相关字段
-- ============================================
ALTER TABLE public.scan_history ADD COLUMN IF NOT EXISTS card_type TEXT;
ALTER TABLE public.scan_history ADD COLUMN IF NOT EXISTS game TEXT;
ALTER TABLE public.scan_history ADD COLUMN IF NOT EXISTS suggested_cards JSONB DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.scan_history.card_type IS 'TCG / NON_TCG / UNKNOWN';
COMMENT ON COLUMN public.scan_history.game IS '游戏/系列名称';
COMMENT ON COLUMN public.scan_history.suggested_cards IS 'AI建议的候选卡牌列表';

-- ============================================
-- 2. ai_scan_logs 添加分类相关字段
-- ============================================
ALTER TABLE public.ai_scan_logs ADD COLUMN IF NOT EXISTS card_type TEXT;
ALTER TABLE public.ai_scan_logs ADD COLUMN IF NOT EXISTS confidence NUMERIC(3,2);

COMMENT ON COLUMN public.ai_scan_logs.card_type IS 'TCG / NON_TCG / UNKNOWN';
COMMENT ON COLUMN public.ai_scan_logs.confidence IS 'AI识别置信度 0.00~1.00';

-- ============================================
-- 3. 待确认卡牌表（非TCG/未知 → 人工确认流程）
-- ============================================
CREATE TABLE IF NOT EXISTS public.pending_card_confirmations (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    image_hash TEXT,
    ai_type TEXT NOT NULL CHECK (ai_type IN ('NON_TCG', 'UNKNOWN')),
    ai_card_name TEXT,
    ai_game TEXT,
    ai_confidence NUMERIC(3,2),
    ai_suggested_cards JSONB DEFAULT '[]'::jsonb,
    ai_reason TEXT,
    confirmed_name TEXT,
    confirmed_game TEXT,
    confirmed_rarity TEXT DEFAULT 'N',
    confirmed_price NUMERIC(12,2),
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'rejected')),
    collection_id UUID REFERENCES public.user_collections(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    confirmed_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_pcc_user ON public.pending_card_confirmations(user_id, status);
CREATE INDEX IF NOT EXISTS idx_pcc_status ON public.pending_card_confirmations(status, created_at DESC);

ALTER TABLE public.pending_card_confirmations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pcc_select_owner" ON public.pending_card_confirmations;
CREATE POLICY "pcc_select_owner" ON public.pending_card_confirmations
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "pcc_insert_owner" ON public.pending_card_confirmations;
CREATE POLICY "pcc_insert_owner" ON public.pending_card_confirmations
    FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "pcc_update_owner" ON public.pending_card_confirmations;
CREATE POLICY "pcc_update_owner" ON public.pending_card_confirmations
    FOR UPDATE USING (auth.uid() = user_id);

COMMENT ON TABLE public.pending_card_confirmations IS '非TCG/未知卡牌人工确认表';
COMMENT ON COLUMN public.pending_card_confirmations.ai_type IS 'AI分类结果';
COMMENT ON COLUMN public.pending_card_confirmations.status IS 'pending=待确认 confirmed=已确认 rejected=已拒绝';

-- ============================================
-- 4. RPC: 原子操作 — 确认pending卡牌并入库
-- ============================================
CREATE OR REPLACE FUNCTION public.resolve_pending_confirmation(
    p_pending_id UUID,
    p_confirmed_name TEXT,
    p_confirmed_game TEXT,
    p_confirmed_rarity TEXT DEFAULT 'N',
    p_confirmed_price NUMERIC DEFAULT 0,
    p_image_url TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_user_id UUID;
    v_collection_id UUID;
    v_pending public.pending_card_confirmations%ROWTYPE;
BEGIN
    -- 获取pending记录
    SELECT * INTO v_pending
    FROM public.pending_card_confirmations
    WHERE id = p_pending_id AND status = 'pending';

    IF v_pending.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', '待确认记录不存在或已处理');
    END IF;

    IF v_pending.user_id != auth.uid() THEN
        RETURN jsonb_build_object('success', false, 'error', '无权操作');
    END IF;

    -- 写入 user_collections
    INSERT INTO public.user_collections (
        user_id, card_name, series, rarity, purchase_price,
        source, card_image, quantity
    ) VALUES (
        v_pending.user_id,
        p_confirmed_name,
        p_confirmed_game,
        p_confirmed_rarity,
        p_confirmed_price,
        'MANUAL',
        p_image_url,
        1
    ) RETURNING id INTO v_collection_id;

    -- 更新 pending 状态
    UPDATE public.pending_card_confirmations
    SET status = 'confirmed',
        confirmed_name = p_confirmed_name,
        confirmed_game = p_confirmed_game,
        confirmed_rarity = p_confirmed_rarity,
        confirmed_price = p_confirmed_price,
        collection_id = v_collection_id,
        confirmed_at = NOW()
    WHERE id = p_pending_id;

    RETURN jsonb_build_object(
        'success', true,
        'collection_id', v_collection_id,
        'message', '卡牌已确认并加入资产'
    );
END;
$$;
