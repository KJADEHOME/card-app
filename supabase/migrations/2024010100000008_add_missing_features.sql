-- ============================================
-- 卡域 - 缺失功能补充：AI识卡记录 + 关注 + 通知 + 投票
-- ============================================

-- 1. AI识卡记录表
CREATE TABLE IF NOT EXISTS public.scan_history (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    card_name TEXT NOT NULL,
    card_name_en TEXT,
    card_image TEXT,
    series TEXT,
    rarity TEXT,
    estimated_price NUMERIC(12,2),
    estimated_currency TEXT DEFAULT 'CNY',
    ai_confidence NUMERIC(3,2),
    scan_type TEXT DEFAULT 'camera' CHECK (scan_type IN ('camera', 'upload')),
    device_info TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_scan_history_user ON public.scan_history(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_scan_history_card ON public.scan_history(card_name);

ALTER TABLE public.scan_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own scans" ON public.scan_history FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users create scans" ON public.scan_history FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 2. 关注/粉丝表
CREATE TABLE IF NOT EXISTS public.user_follows (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    follower_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    following_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(follower_id, following_id)
);

CREATE INDEX IF NOT EXISTS idx_follows_follower ON public.user_follows(follower_id);
CREATE INDEX IF NOT EXISTS idx_follows_following ON public.user_follows(following_id);

ALTER TABLE public.user_follows ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view follows" ON public.user_follows FOR SELECT USING (true);
CREATE POLICY "Users can follow" ON public.user_follows FOR INSERT WITH CHECK (auth.uid() = follower_id);
CREATE POLICY "Users can unfollow" ON public.user_follows FOR DELETE USING (auth.uid() = follower_id);

-- 3. 通知中心表
CREATE TABLE IF NOT EXISTS public.notifications (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('order', 'comment', 'like', 'follow', 'system', 'trade', 'promo')),
    title TEXT NOT NULL,
    content TEXT,
    reference_id UUID,
    reference_type TEXT,
    is_read BOOLEAN DEFAULT false,
    action_url TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_unread ON public.notifications(user_id, is_read);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own notifications" ON public.notifications FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users mark read" ON public.notifications FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users delete own" ON public.notifications FOR DELETE USING (auth.uid() = user_id);

-- 4. 投票系统表
CREATE TABLE IF NOT EXISTS public.votes (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    post_id UUID REFERENCES public.community_posts(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    question TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE,
    UNIQUE(post_id)
);

CREATE TABLE IF NOT EXISTS public.vote_options (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    vote_id UUID REFERENCES public.votes(id) ON DELETE CASCADE NOT NULL,
    option_text TEXT NOT NULL,
    vote_count INTEGER DEFAULT 0,
    sort_order INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.vote_records (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    vote_id UUID REFERENCES public.votes(id) ON DELETE CASCADE NOT NULL,
    option_id UUID REFERENCES public.vote_options(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(vote_id, user_id)
);

ALTER TABLE public.votes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vote_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vote_records ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view votes" ON public.votes FOR SELECT USING (true);
CREATE POLICY "Users can create votes" ON public.votes FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Anyone can view options" ON public.vote_options FOR SELECT USING (true);
CREATE POLICY "Users can vote" ON public.vote_records FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 5. 成交记录表（用于行情TOP10和交易量统计）
CREATE TABLE IF NOT EXISTS public.trade_records (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
    card_name TEXT NOT NULL,
    card_name_en TEXT,
    series TEXT,
    rarity TEXT,
    price NUMERIC(12,2) NOT NULL,
    currency TEXT DEFAULT 'CNY',
    condition TEXT,
    seller_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    buyer_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    traded_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trade_records_date ON public.trade_records(traded_at DESC);
CREATE INDEX IF NOT EXISTS idx_trade_records_card ON public.trade_records(card_name);

ALTER TABLE public.trade_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view trades" ON public.trade_records FOR SELECT USING (true);

-- 6. 触发器：新关注时发通知
CREATE OR REPLACE FUNCTION notify_on_follow()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.notifications (user_id, type, title, content, reference_id, reference_type)
    VALUES (NEW.following_id, 'follow', '新粉丝', '有人关注了你', NEW.follower_id, 'user');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notify_follow ON public.user_follows;
CREATE TRIGGER trg_notify_follow
    AFTER INSERT ON public.user_follows
    FOR EACH ROW EXECUTE FUNCTION notify_on_follow();

-- 7. 触发器：评论时发通知
CREATE OR REPLACE FUNCTION notify_on_comment()
RETURNS TRIGGER AS $$
DECLARE
    v_post_user UUID;
BEGIN
    SELECT user_id INTO v_post_user FROM public.community_posts WHERE id = NEW.post_id;
    IF v_post_user IS NOT NULL AND v_post_user != NEW.user_id THEN
        INSERT INTO public.notifications (user_id, type, title, content, reference_id, reference_type, action_url)
        VALUES (v_post_user, 'comment', '新评论', '有人评论了你的帖子', NEW.post_id, 'post', '/community.html?post=' || NEW.post_id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notify_comment ON public.community_comments;
CREATE TRIGGER trg_notify_comment
    AFTER INSERT ON public.community_comments
    FOR EACH ROW EXECUTE FUNCTION notify_on_comment();

-- 8. 触发器：点赞时发通知
CREATE OR REPLACE FUNCTION notify_on_like()
RETURNS TRIGGER AS $$
DECLARE
    v_post_user UUID;
BEGIN
    SELECT user_id INTO v_post_user FROM public.community_posts WHERE id = NEW.post_id;
    IF v_post_user IS NOT NULL AND v_post_user != NEW.user_id THEN
        INSERT INTO public.notifications (user_id, type, title, content, reference_id, reference_type)
        VALUES (v_post_user, 'like', '新点赞', '有人赞了你的帖子', NEW.post_id, 'post');
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notify_like ON public.post_likes;
CREATE TRIGGER trg_notify_like
    AFTER INSERT ON public.post_likes
    FOR EACH ROW EXECUTE FUNCTION notify_on_like();
