-- ============================================
-- 卡域 - 数据看板支撑表
-- 价格历史 + 搜索日志 + 每日市场统计
-- ============================================

-- 1. 卡牌价格历史（每日快照）
CREATE TABLE IF NOT EXISTS public.price_history (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    card_id TEXT NOT NULL,
    card_name TEXT NOT NULL,
    card_category TEXT NOT NULL,           -- pokemon, yugioh, mtg, etc.
    price_low NUMERIC(12,2),
    price_mid NUMERIC(12,2),
    price_high NUMERIC(12,2),
    currency TEXT DEFAULT 'CNY',
    market TEXT DEFAULT 'CN',              -- CN / US / JP
    date DATE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(card_id, market, date)
);

CREATE INDEX IF NOT EXISTS idx_price_history_card ON public.price_history(card_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_price_history_category ON public.price_history(card_category, date DESC);

-- 2. 搜索日志
CREATE TABLE IF NOT EXISTS public.search_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    query TEXT NOT NULL,
    category TEXT,                         -- 用户选择的筛选品类
    results_count INTEGER DEFAULT 0,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_search_logs_query ON public.search_logs(query, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_search_logs_date ON public.search_logs(created_at DESC);

-- 3. 每日市场统计（聚合表，加速看板查询）
CREATE TABLE IF NOT EXISTS public.daily_market_stats (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    date DATE NOT NULL UNIQUE,
    category TEXT NOT NULL DEFAULT 'pokemon',
    total_cards INTEGER DEFAULT 0,
    rising_count INTEGER DEFAULT 0,
    falling_count INTEGER DEFAULT 0,
    avg_change_pct NUMERIC(5,2),
    total_volume INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_daily_stats_date ON public.daily_market_stats(date DESC);

-- RLS
ALTER TABLE public.price_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.search_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_market_stats ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read price history" ON public.price_history;
CREATE POLICY "Anyone can read price history" ON public.price_history FOR SELECT USING (true);

DROP POLICY IF EXISTS "Anyone can insert search logs" ON public.search_logs;
CREATE POLICY "Anyone can insert search logs" ON public.search_logs FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS "Admins can view search logs" ON public.search_logs;
CREATE POLICY "Admins can view search logs" ON public.search_logs FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE profiles.id = auth.uid() AND profiles.username = 'admin')
);

DROP POLICY IF EXISTS "Anyone can read market stats" ON public.daily_market_stats;
CREATE POLICY "Anyone can read market stats" ON public.daily_market_stats FOR SELECT USING (true);

-- 注释
COMMENT ON TABLE public.price_history IS '卡牌每日价格快照';
COMMENT ON TABLE public.search_logs IS '用户搜索行为日志';
COMMENT ON TABLE public.daily_market_stats IS '每日市场统计数据（预聚合）';
