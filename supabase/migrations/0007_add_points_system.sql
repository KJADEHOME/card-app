-- ============================================
-- 卡域 - 积分与用户等级体系（留存与付费激励）
-- ============================================

-- 1. 用户积分表
CREATE TABLE IF NOT EXISTS public.user_points (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE NOT NULL,
    
    current_points INTEGER DEFAULT 0,                  -- 当前可用积分
    total_earned INTEGER DEFAULT 0,                    -- 累计获得积分
    total_spent INTEGER DEFAULT 0,                     -- 累计消耗积分
    
    checkin_streak INTEGER DEFAULT 0,                  -- 连续签到天数
    last_checkin_date DATE,                            -- 上次签到日期
    total_checkins INTEGER DEFAULT 0,                  -- 累计签到次数
    
    exp INTEGER DEFAULT 0,                             -- 经验值
    level INTEGER DEFAULT 1,                           -- 当前等级
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_points_user ON public.user_points(user_id);

-- 2. 积分流水表
CREATE TABLE IF NOT EXISTS public.point_transactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    
    points INTEGER NOT NULL,                           -- 正数=获得，负数=消耗
    balance_after INTEGER NOT NULL,                    -- 变动后余额
    
    type TEXT NOT NULL CHECK (type IN (
        'checkin',           -- 每日签到
        'checkin_streak',    -- 连续签到奖励
        'scan',              -- AI识卡奖励
        'scan_discount',     -- AI识卡积分抵扣
        'share',             -- 分享社区
        'invite',            -- 邀请好友
        'purchase',          -- 消费返积分
        'levelup',           -- 升级奖励
        'admin_gift',        -- 运营赠送
        'expire'             -- 积分过期
    )),
    
    description TEXT,
    reference_id UUID,                                 -- 关联订单/识卡记录
    reference_type TEXT,                               -- order/scan/invite
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_point_tx_user ON public.point_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_point_tx_created ON public.point_transactions(created_at DESC);

-- 3. 签到记录表
CREATE TABLE IF NOT EXISTS public.daily_checkins (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    checkin_date DATE NOT NULL,
    points_awarded INTEGER DEFAULT 0,
    streak_day INTEGER DEFAULT 1,                      -- 当天是第几天连续
    
    UNIQUE(user_id, checkin_date)
);

CREATE INDEX IF NOT EXISTS idx_checkins_user_date ON public.daily_checkins(user_id, checkin_date DESC);

-- 4. 等级配置表
CREATE TABLE IF NOT EXISTS public.level_config (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    level INTEGER UNIQUE NOT NULL,
    title TEXT NOT NULL,                               -- 等级称号
    exp_required INTEGER NOT NULL,                     -- 升到该等级所需经验
    
    -- 特权
    scan_discount_pct INTEGER DEFAULT 0,               -- AI识卡手续费减免(%)
    daily_checkin_bonus INTEGER DEFAULT 0,             -- 每日签到额外积分
    listing_fee_discount INTEGER DEFAULT 0,            -- 寄售手续费减免(%)
    priority_support BOOLEAN DEFAULT false,            -- 优先客服
    special_badge TEXT,                                -- 专属徽章/称号颜色
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 插入等级配置
INSERT INTO public.level_config (level, title, exp_required, scan_discount_pct, daily_checkin_bonus, listing_fee_discount, priority_support, special_badge) VALUES
    (1, '卡牌新手', 0, 0, 0, 0, false, '🌱'),
    (2, '卡牌学徒', 100, 0, 1, 0, false, '⭐'),
    (3, '卡牌达人', 300, 5, 2, 0, false, '💫'),
    (4, '卡牌专家', 600, 5, 3, 5, false, '🏅'),
    (5, '卡牌大师', 1000, 10, 5, 10, true, '🎖️'),
    (6, '卡牌宗师', 2000, 15, 8, 15, true, '👑'),
    (7, '卡牌传说', 5000, 20, 10, 20, true, '💎')
ON CONFLICT (level) DO NOTHING;

-- 触发器：新用户自动创建积分记录
CREATE OR REPLACE FUNCTION create_user_points()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.user_points (user_id) VALUES (NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_create_points ON auth.users;
CREATE TRIGGER trg_create_points
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION create_user_points();

-- 触发器：积分变动自动更新累计值
CREATE OR REPLACE FUNCTION update_user_points_on_tx()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.points > 0 THEN
        UPDATE public.user_points SET
            current_points = current_points + NEW.points,
            total_earned = total_earned + NEW.points,
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
    ELSE
        UPDATE public.user_points SET
            current_points = current_points + NEW.points,
            total_spent = total_spent + ABS(NEW.points),
            updated_at = NOW()
        WHERE user_id = NEW.user_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_points ON public.point_transactions;
CREATE TRIGGER trg_update_points
    AFTER INSERT ON public.point_transactions
    FOR EACH ROW EXECUTE FUNCTION update_user_points_on_tx();

-- 触发器：签到时更新连续天数和积分
CREATE OR REPLACE FUNCTION process_checkin()
RETURNS TRIGGER AS $$
DECLARE
    v_last_date DATE;
    v_streak INTEGER;
    v_points INTEGER;
    v_level_bonus INTEGER;
BEGIN
    -- 获取用户当前积分信息
    SELECT last_checkin_date, checkin_streak INTO v_last_date, v_streak
    FROM public.user_points WHERE user_id = NEW.user_id;
    
    -- 计算连续天数
    IF v_last_date = CURRENT_DATE - INTERVAL '1 day' THEN
        v_streak := v_streak + 1;
    ELSIF v_last_date = CURRENT_DATE THEN
        -- 今天已经签到过了，不处理
        RETURN NULL;
    ELSE
        v_streak := 1;
    END IF;
    
    -- 基础积分 + 连续奖励
    v_points := 5;
    IF v_streak >= 7 THEN v_points := v_points + 10;
    ELSIF v_streak >= 3 THEN v_points := v_points + 3;
    END IF;
    
    -- 更新签到记录
    NEW.streak_day := v_streak;
    NEW.points_awarded := v_points;
    
    -- 更新用户积分
    UPDATE public.user_points SET
        checkin_streak = v_streak,
        last_checkin_date = CURRENT_DATE,
        total_checkins = total_checkins + 1,
        current_points = current_points + v_points,
        total_earned = total_earned + v_points,
        updated_at = NOW()
    WHERE user_id = NEW.user_id;
    
    -- 记录积分流水
    INSERT INTO public.point_transactions (user_id, points, balance_after, type, description)
    SELECT NEW.user_id, v_points, current_points, 'checkin',
        '每日签到 +' || v_points || ' 积分（连续' || v_streak || '天）'
    FROM public.user_points WHERE user_id = NEW.user_id;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_process_checkin ON public.daily_checkins;
CREATE TRIGGER trg_process_checkin
    BEFORE INSERT ON public.daily_checkins
    FOR EACH ROW EXECUTE FUNCTION process_checkin();

-- RLS
ALTER TABLE public.user_points ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.point_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_checkins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.level_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users own points" ON public.user_points;
CREATE POLICY "Users own points" ON public.user_points
    FOR ALL USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users view own tx" ON public.point_transactions;
CREATE POLICY "Users view own tx" ON public.point_transactions
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users view own checkins" ON public.daily_checkins;
CREATE POLICY "Users view own checkins" ON public.daily_checkins
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Anyone can view levels" ON public.level_config;
CREATE POLICY "Anyone can view levels" ON public.level_config
    FOR SELECT USING (true);
