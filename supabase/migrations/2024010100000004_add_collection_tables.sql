-- ============================================
-- 卡域 - 个人资产估值 & 收藏夹系统
-- ============================================

-- 1. 用户收藏夹
CREATE TABLE IF NOT EXISTS public.user_collections (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    card_id TEXT,                          -- 外部卡牌ID（如TCGdex ID）
    card_name TEXT NOT NULL,
    card_name_en TEXT,                     -- 英文原名
    card_image TEXT,                       -- 卡牌图片URL
    series TEXT,                           -- 系列/卡包
    rarity TEXT,                           -- 稀有度
    card_category TEXT DEFAULT 'pokemon',  -- pokemon, yugioh, mtg, etc.
    condition TEXT DEFAULT 'NM' CHECK (condition IN ('M', 'NM', 'LP', 'MP', 'HP', 'D')), -- 品相
    purchase_price NUMERIC(12,2),          -- 入手价
    purchase_currency TEXT DEFAULT 'CNY',
    purchase_date DATE,
    current_price NUMERIC(12,2),           -- 当前市场价（自动更新）
    current_currency TEXT DEFAULT 'CNY',
    quantity INTEGER DEFAULT 1,
    notes TEXT,
    is_favorite BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_collections_user ON public.user_collections(user_id);
CREATE INDEX IF NOT EXISTS idx_user_collections_category ON public.user_collections(card_category);

-- 2. 资产每日快照（用于资产曲线）
CREATE TABLE IF NOT EXISTS public.collection_price_snapshots (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    date DATE NOT NULL,
    total_cost NUMERIC(14,2) DEFAULT 0,      -- 总投入
    total_value NUMERIC(14,2) DEFAULT 0,     -- 总市值
    total_profit NUMERIC(14,2) DEFAULT 0,    -- 总盈亏
    profit_pct NUMERIC(6,2) DEFAULT 0,       -- 盈亏率 %
    card_count INTEGER DEFAULT 0,            -- 持有卡牌数
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, date)
);

CREATE INDEX IF NOT EXISTS idx_snapshots_user_date ON public.collection_price_snapshots(user_id, date DESC);

-- 触发器：更新 updated_at
CREATE OR REPLACE TRIGGER update_collections_updated_at
    BEFORE UPDATE ON public.user_collections
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS
ALTER TABLE public.user_collections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.collection_price_snapshots ENABLE ROW LEVEL SECURITY;

-- 用户只能看/改自己的收藏
DROP POLICY IF EXISTS "Users own their collections" ON public.user_collections;
CREATE POLICY "Users own their collections" ON public.user_collections
    FOR ALL USING (auth.uid() = user_id);

-- 用户只能看自己的资产快照
DROP POLICY IF EXISTS "Users own their snapshots" ON public.collection_price_snapshots;
CREATE POLICY "Users own their snapshots" ON public.collection_price_snapshots
    FOR ALL USING (auth.uid() = user_id);

-- 注释
COMMENT ON TABLE public.user_collections IS '用户收藏夹，记录每张入手卡牌及价格';
COMMENT ON TABLE public.collection_price_snapshots IS '用户资产每日快照，用于绘制资产曲线';
COMMENT ON COLUMN public.user_collections.condition IS '品相: M=完美, NM=近新, LP=轻损, MP=中损, HP=重损, D=损坏';
