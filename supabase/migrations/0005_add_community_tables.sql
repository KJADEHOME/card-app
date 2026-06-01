-- ============================================
-- 卡域 - AI识卡社区化系统
-- 帖子 / 评论 / 点赞 / 热门识别榜
-- ============================================

-- 1. 社区帖子（AI识卡分享）
CREATE TABLE IF NOT EXISTS public.community_posts (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    card_name TEXT NOT NULL,
    card_name_en TEXT,
    card_image TEXT,                       -- 用户上传的卡牌照片
    card_image_processed TEXT,             -- 系统生成的分享海报
    series TEXT,
    rarity TEXT,
    estimated_price NUMERIC(12,2),
    estimated_currency TEXT DEFAULT 'CNY',
    purchase_price NUMERIC(12,2),          -- 用户填写的入手价
    user_note TEXT,                        -- 用户分享时写的话
    likes INTEGER DEFAULT 0,
    comments INTEGER DEFAULT 0,
    views INTEGER DEFAULT 0,
    is_featured BOOLEAN DEFAULT false,     -- 是否精选
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_posts_user ON public.community_posts(user_id);
CREATE INDEX IF NOT EXISTS idx_posts_created ON public.community_posts(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_featured ON public.community_posts(is_featured, created_at DESC);

-- 2. 帖子评论
CREATE TABLE IF NOT EXISTS public.community_comments (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    post_id UUID REFERENCES public.community_posts(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_comments_post ON public.community_comments(post_id, created_at DESC);

-- 3. 点赞记录
CREATE TABLE IF NOT EXISTS public.post_likes (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    post_id UUID REFERENCES public.community_posts(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(post_id, user_id)
);

-- 4. 热门识别统计（每日/每周）
CREATE TABLE IF NOT EXISTS public.trending_scans (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    card_name TEXT NOT NULL,
    card_name_en TEXT,
    series TEXT,
    scan_count INTEGER DEFAULT 1,
    avg_price NUMERIC(12,2),
    period TEXT NOT NULL CHECK (period IN ('day', 'week', 'month')),
    date DATE NOT NULL,
    UNIQUE(card_name, period, date)
);

CREATE INDEX IF NOT EXISTS idx_trending_period ON public.trending_scans(period, date DESC, scan_count DESC);

-- RLS
ALTER TABLE public.community_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.community_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_likes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trending_scans ENABLE ROW LEVEL SECURITY;

-- 所有人可浏览
DROP POLICY IF EXISTS "Anyone can view posts" ON public.community_posts;
CREATE POLICY "Anyone can view posts" ON public.community_posts FOR SELECT USING (true);

-- 登录用户可发帖
DROP POLICY IF EXISTS "Users can create posts" ON public.community_posts;
CREATE POLICY "Users can create posts" ON public.community_posts FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 只能删自己的
DROP POLICY IF EXISTS "Users can delete own posts" ON public.community_posts;
CREATE POLICY "Users can delete own posts" ON public.community_posts FOR DELETE USING (auth.uid() = user_id);

-- 评论
DROP POLICY IF EXISTS "Anyone can view comments" ON public.community_comments;
CREATE POLICY "Anyone can view comments" ON public.community_comments FOR SELECT USING (true);
DROP POLICY IF EXISTS "Users can create comments" ON public.community_comments;
CREATE POLICY "Users can create comments" ON public.community_comments FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 点赞
DROP POLICY IF EXISTS "Anyone can view likes" ON public.post_likes;
CREATE POLICY "Anyone can view likes" ON public.post_likes FOR SELECT USING (true);
DROP POLICY IF EXISTS "Users can like" ON public.post_likes;
CREATE POLICY "Users can like" ON public.post_likes FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 热门榜
DROP POLICY IF EXISTS "Anyone can view trending" ON public.trending_scans;
CREATE POLICY "Anyone can view trending" ON public.trending_scans FOR SELECT USING (true);

-- 注释
COMMENT ON TABLE public.community_posts IS 'AI识卡社区分享帖子';
COMMENT ON TABLE public.community_comments IS '帖子评论';
COMMENT ON TABLE public.post_likes IS '帖子点赞记录';
COMMENT ON TABLE public.trending_scans IS '热门识别统计';
