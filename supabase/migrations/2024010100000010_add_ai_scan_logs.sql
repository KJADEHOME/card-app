-- ============================================
-- 卡域 - AI扫描防刷 & 完整闭环增强
-- ============================================

-- 1. AI扫描日志表（防刷核心）
CREATE TABLE IF NOT EXISTS public.ai_scan_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    image_hash TEXT NOT NULL,                       -- SHA256 图片指纹
    card_name TEXT,                                 -- 识别的卡名
    series TEXT,                                    -- 卡牌系列
    rarity TEXT,                                    -- 稀有度
    collection_id UUID REFERENCES public.user_collections(id) ON DELETE SET NULL,  -- 关联的收藏记录
    scan_history_id UUID REFERENCES public.scan_history(id) ON DELETE SET NULL,    -- 关联的扫描记录
    points_cost INTEGER DEFAULT 0,                  -- 本次消耗积分
    points_discounted INTEGER DEFAULT 0,            -- 等级减免积分
    points_base INTEGER DEFAULT 10,                -- 基础消耗积分
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_scan_logs_user ON public.ai_scan_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_ai_scan_logs_hash ON public.ai_scan_logs(user_id, image_hash);
CREATE INDEX IF NOT EXISTS idx_ai_scan_logs_date ON public.ai_scan_logs(user_id, created_at DESC);

ALTER TABLE public.ai_scan_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own scan logs" ON public.ai_scan_logs FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users create scan logs" ON public.ai_scan_logs FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 2. scan_history 添加 image_hash 字段（用于关联和去重）
ALTER TABLE public.scan_history ADD COLUMN IF NOT EXISTS image_hash TEXT;
ALTER TABLE public.scan_history ADD COLUMN IF NOT EXISTS collection_id UUID REFERENCES public.user_collections(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_scan_history_hash ON public.scan_history(user_id, image_hash);

-- 3. user_collections 添加来源追踪
ALTER TABLE public.user_collections ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'MANUAL';
COMMENT ON COLUMN public.user_collections.source IS '来源: AI_SCAN=AI识卡, MANUAL=手动录入, IMPORT=导入, TRADE=交易获得';

-- 4. AI扫描积分消耗配置（加入 platform_config）
INSERT INTO public.platform_config (key, value, description) VALUES
    ('scan_base_points_cost', '10', 'AI识卡基础积分消耗'),
    ('scan_daily_limit', '50', '每日AI识卡上限次数'),
    ('scan_cooldown_minutes', '0', 'AI识卡冷却时间（分钟），0=无冷却')
ON CONFLICT (key) DO NOTHING;

-- 5. RPC: 检查用户今日扫描次数
CREATE OR REPLACE FUNCTION check_scan_limit(p_user_id UUID)
RETURNS TABLE(
    today_scans BIGINT,
    daily_limit INTEGER,
    can_scan BOOLEAN
) AS $$
DECLARE
    v_today DATE := CURRENT_DATE;
    v_count BIGINT;
    v_limit INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM public.ai_scan_logs
    WHERE user_id = p_user_id AND created_at::DATE = v_today;
    
    SELECT COALESCE((SELECT value::INTEGER FROM public.platform_config WHERE key = 'scan_daily_limit'), 50) INTO v_limit;
    
    today_scans := v_count;
    daily_limit := v_limit;
    can_scan := v_count < v_limit;
    
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. RPC: 扣除AI扫描积分（原子操作）
CREATE OR REPLACE FUNCTION deduct_scan_points(
    p_user_id UUID,
    p_points INTEGER,
    p_card_name TEXT,
    p_scan_log_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
    v_current INTEGER;
    v_after INTEGER;
BEGIN
    -- 锁定并获取当前积分
    SELECT current_points INTO v_current
    FROM public.user_points
    WHERE user_id = p_user_id
    FOR UPDATE;
    
    IF v_current IS NULL OR v_current < p_points THEN
        RETURN FALSE;
    END IF;
    
    v_after := v_current - p_points;
    
    -- 扣减积分
    UPDATE public.user_points SET
        current_points = v_after,
        total_spent = total_spent + p_points,
        updated_at = NOW()
    WHERE user_id = p_user_id;
    
    -- 记录流水
    INSERT INTO public.point_transactions (user_id, points, balance_after, type, description, reference_id, reference_type)
    VALUES (p_user_id, -p_points, v_after, 'scan_discount',
            'AI识卡「' || COALESCE(p_card_name, '未知') || '」消耗积分',
            p_scan_log_id, 'scan');
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. 触发器：新用户自动创建 user_points（如果没有）
-- （已存在于 0007 migration，这里做幂等处理）
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger WHERE tgname = 'trg_create_points'
    ) THEN
        CREATE TRIGGER trg_create_points
        AFTER INSERT ON auth.users
        FOR EACH ROW EXECUTE FUNCTION create_user_points();
    END IF;
END $$;

COMMENT ON TABLE public.ai_scan_logs IS 'AI识卡日志，用于防刷和积分扣费追踪';
COMMENT ON COLUMN public.ai_scan_logs.image_hash IS '图片SHA256哈希，用于去重';
COMMENT ON COLUMN public.ai_scan_logs.points_cost IS '本次扫描实际消耗积分';
COMMENT ON COLUMN public.ai_scan_logs.points_discounted IS '等级减免的积分';
COMMENT ON COLUMN public.ai_scan_logs.points_base IS '基础消耗积分';

-- ============================================
-- 8. Storage Bucket 设置（需在 SQL Editor 执行）
-- ============================================
-- 创建 card-scans bucket 的 RLS 策略（bucket 本身需在 Dashboard → Storage 手动创建）
-- Bucket 名称: card-scans
-- 勾选: Public bucket（公开访问）

-- Storage 对象级别的 RLS 策略
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('card-scans', 'card-scans', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE SET
    public = true,
    file_size_limit = 5242880,
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp'];

-- Storage RLS：认证用户可上传
CREATE POLICY "Authenticated users can upload card scans"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
    bucket_id = 'card-scans'
    AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Storage RLS：公开可读取
CREATE POLICY "Public can view card scans"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'card-scans');
