-- ============================================================
-- 0013: 风控 + 防刷 + 成本控制系统
-- CardRealm MVP第四阶段 —— 真实流量下的安全保障
-- ============================================================
-- 依赖: 0010 (ai_scan_logs), 0007 (user_points/point_transactions), 0012 (trading)
-- 本文件自包含: 所有 CREATE IF NOT EXISTS，可安全重复执行
-- ============================================================

-- ============================================================
-- 一、AI识卡防刷增强
-- ============================================================

-- 1.1 AI扫描结果缓存表（7天TTL，同图不重复调用AI）
CREATE TABLE IF NOT EXISTS public.ai_scan_cache (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    image_hash TEXT NOT NULL,                          -- SHA256 图片指纹
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    result_json JSONB NOT NULL,                        -- AI识别结果
    card_name TEXT,
    series TEXT,
    rarity TEXT,
    ai_cost_cny NUMERIC(10,4) DEFAULT 0,               -- 本次AI调用成本(元)
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    expires_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() + INTERVAL '7 days',
    UNIQUE(image_hash)
);

CREATE INDEX IF NOT EXISTS idx_ai_cache_hash ON public.ai_scan_cache(image_hash);
CREATE INDEX IF NOT EXISTS idx_ai_cache_expires ON public.ai_scan_cache(expires_at);

ALTER TABLE public.ai_scan_cache ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own cache" ON public.ai_scan_cache FOR SELECT USING (true);
CREATE POLICY "Auth users write cache" ON public.ai_scan_cache FOR INSERT TO authenticated WITH CHECK (true);

-- 1.2 AI成本记录表（追踪每次AI调用的实际费用）
CREATE TABLE IF NOT EXISTS public.ai_cost_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    request_type TEXT DEFAULT 'card_scan',              -- card_scan / price_lookup / other
    model TEXT DEFAULT 'moonshot-v1-128k-vision-preview',
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cost_cny NUMERIC(10,4) DEFAULT 0,                   -- 本次调用成本(人民币)
    cost_usd NUMERIC(10,6) DEFAULT 0,                   -- 美元成本
    cached BOOLEAN DEFAULT false,                       -- 是否命中缓存
    image_hash TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ai_cost_user_date ON public.ai_cost_logs(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ai_cost_date ON public.ai_cost_logs(created_at DESC);

ALTER TABLE public.ai_cost_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own cost logs" ON public.ai_cost_logs FOR SELECT USING (auth.uid() = user_id);

-- 1.3 AI成本预算配置
INSERT INTO public.platform_config (key, value, description) VALUES
    ('ai_daily_cost_limit_free', '2.00', '免费用户每日AI成本上限(元)'),
    ('ai_daily_cost_limit_paid', '10.00', '付费用户每日AI成本上限(元)'),
    ('ai_per_call_cost_cny', '0.015', '单次AI识卡预估成本(元)'),
    ('ai_cache_ttl_hours', '168', 'AI识卡缓存有效期(小时, 168=7天)'),
    ('ai_rate_limit_per_minute', '1', 'AI识卡每分钟限频(次)'),
    ('ai_rate_limit_per_day', '10', 'AI识卡每日限频(次)'),
    ('trade_max_pair_per_day', '3', '同一买卖双方每日最大交易次数'),
    ('trade_min_interval_seconds', '10', '同一用户最小交易间隔(秒)'),
    ('risk_points_daily_threshold', '200', '单日积分增长风控阈值'),
    ('risk_ai_consecutive_threshold', '10', '连续AI识卡风控阈值')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- 二、用户风控等级系统
-- ============================================================

-- 2.1 用户风控等级表
CREATE TABLE IF NOT EXISTS public.user_risk_levels (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE NOT NULL,
    risk_level SMALLINT DEFAULT 0,                      -- 0=正常, 1=高频, 2=风险, 3=封禁
    risk_score INTEGER DEFAULT 0,                       -- 风控评分(越高越危险)
    flags TEXT[] DEFAULT ARRAY[]::TEXT[],               -- 风控标签: ['ai_abuse','trade_shill','points_farm',...]
    restricted_features TEXT[] DEFAULT ARRAY[]::TEXT[], -- 被限制的功能: ['ai_scan','trade','signin']
    restricted_until TIMESTAMP WITH TIME ZONE,          -- 限制截止时间
    last_evaluated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    note TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_risk_user ON public.user_risk_levels(user_id);
CREATE INDEX IF NOT EXISTS idx_risk_level ON public.user_risk_levels(risk_level);

ALTER TABLE public.user_risk_levels ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users view own risk level" ON public.user_risk_levels FOR SELECT USING (auth.uid() = user_id);

-- 2.2 风控事件日志表（审计追踪）
CREATE TABLE IF NOT EXISTS public.risk_events (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    event_type TEXT NOT NULL,                           -- ai_rate_exceeded / trade_shill_detected / points_anomaly / ...
    severity TEXT DEFAULT 'warning',                    -- info / warning / critical
    detail JSONB,
    ip_address TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_risk_events_user ON public.risk_events(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_risk_events_type ON public.risk_events(event_type, created_at DESC);

ALTER TABLE public.risk_events ENABLE ROW LEVEL SECURITY;
-- 仅service_role可读写(SECURITY DEFINER函数操作)
REVOKE ALL ON public.risk_events FROM authenticated, anon;

-- ============================================================
-- 三、交易防刷增强
-- ============================================================

-- 3.1 交易频率日志表（用于检测互刷）
CREATE TABLE IF NOT EXISTS public.trade_frequency_logs (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    buyer_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    seller_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    consignment_id UUID,
    order_id UUID,
    card_name TEXT,
    amount NUMERIC(12,2),
    ip_address TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trade_freq_pair ON public.trade_frequency_logs(buyer_id, seller_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trade_freq_user ON public.trade_frequency_logs(buyer_id, created_at DESC);

ALTER TABLE public.trade_frequency_logs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.trade_frequency_logs FROM authenticated, anon;

-- 3.2 orders 表增加幂等键
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS idempotency_key TEXT;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS ip_address TEXT;
CREATE INDEX IF NOT EXISTS idx_orders_idempotency ON public.orders(idempotency_key) WHERE idempotency_key IS NOT NULL;

-- ============================================================
-- 四、RPC 函数
-- ============================================================

-- ============================================================
-- RPC 1: 获取缓存的AI识卡结果（7天TTL）
-- 命中缓存 → 返回结果 + cached=true（不调用AI，不扣积分）
-- ============================================================
CREATE OR REPLACE FUNCTION get_cached_scan_result(
    p_image_hash TEXT
) RETURNS JSON AS $$
DECLARE
    v_cache RECORD;
BEGIN
    SELECT * INTO v_cache
    FROM public.ai_scan_cache
    WHERE image_hash = p_image_hash
      AND expires_at > NOW()
    LIMIT 1;

    IF FOUND THEN
        RETURN json_build_object(
            'cached', true,
            'data', v_cache.result_json,
            'cached_at', v_cache.created_at
        );
    END IF;

    RETURN json_build_object('cached', false);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 2: 缓存AI识卡结果
-- ============================================================
CREATE OR REPLACE FUNCTION cache_scan_result(
    p_user_id UUID,
    p_image_hash TEXT,
    p_result_json JSONB,
    p_card_name TEXT DEFAULT NULL,
    p_series TEXT DEFAULT NULL,
    p_rarity TEXT DEFAULT NULL,
    p_cost_cny NUMERIC DEFAULT 0
) RETURNS VOID AS $$
BEGIN
    INSERT INTO public.ai_scan_cache (image_hash, user_id, result_json, card_name, series, rarity, ai_cost_cny, expires_at)
    VALUES (
        p_image_hash, p_user_id, p_result_json,
        p_card_name, p_series, p_rarity, p_cost_cny,
        NOW() + (SELECT COALESCE(value::INTEGER, 168) FROM public.platform_config WHERE key = 'ai_cache_ttl_hours') * INTERVAL '1 hour'
    )
    ON CONFLICT (image_hash) DO UPDATE SET
        result_json = EXCLUDED.result_json,
        card_name = EXCLUDED.card_name,
        series = EXCLUDED.series,
        rarity = EXCLUDED.rarity,
        ai_cost_cny = EXCLUDED.ai_cost_cny,
        expires_at = EXCLUDED.expires_at,
        created_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 3: AI识卡频率限制检查（每日 + 每分钟）
-- ============================================================
CREATE OR REPLACE FUNCTION check_ai_rate_limit(
    p_user_id UUID
) RETURNS TABLE(
    can_scan BOOLEAN,
    daily_used INTEGER,
    daily_limit INTEGER,
    cooldown_remaining INTEGER,  -- 剩余冷却秒数
    risk_blocked BOOLEAN,
    error_msg TEXT
) AS $$
DECLARE
    v_daily_count INTEGER;
    v_daily_limit INTEGER;
    v_minute_limit INTEGER;
    v_last_scan TIMESTAMP WITH TIME ZONE;
    v_cooldown_sec INTEGER;
    v_risk RECORD;
BEGIN
    -- 检查风控等级
    SELECT * INTO v_risk FROM public.user_risk_levels WHERE user_id = p_user_id;

    IF FOUND AND v_risk.risk_level >= 3 THEN
        can_scan := false;
        daily_used := 0;
        daily_limit := 0;
        cooldown_remaining := 0;
        risk_blocked := true;
        error_msg := '账号已被封禁，请联系客服';
        RETURN NEXT;
        RETURN;
    END IF;

    IF FOUND AND v_risk.risk_level = 2 AND COALESCE(v_risk.restricted_features, ARRAY[]::TEXT[]) @> ARRAY['ai_scan'] THEN
        IF v_risk.restricted_until IS NULL OR v_risk.restricted_until > NOW() THEN
            can_scan := false;
            daily_used := 0;
            daily_limit := 0;
            cooldown_remaining := 0;
            risk_blocked := true;
            error_msg := 'AI识卡功能已被临时限制';
            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    -- 今日扫描次数
    SELECT COUNT(*) INTO v_daily_count
    FROM public.ai_scan_logs
    WHERE user_id = p_user_id AND created_at::DATE = CURRENT_DATE;

    SELECT COALESCE(
        (SELECT value::INTEGER FROM public.platform_config WHERE key = 'ai_rate_limit_per_day'),
        10
    ) INTO v_daily_limit;

    IF v_daily_count >= v_daily_limit THEN
        can_scan := false;
        daily_used := v_daily_count;
        daily_limit := v_daily_limit;
        cooldown_remaining := 0;
        risk_blocked := false;
        error_msg := '今日AI识卡已达上限(' || v_daily_limit || '次)';
        RETURN NEXT;
        RETURN;
    END IF;

    -- 每分钟频率限制
    SELECT COALESCE(
        (SELECT value::INTEGER FROM public.platform_config WHERE key = 'ai_rate_limit_per_minute'),
        1
    ) INTO v_minute_limit;

    SELECT created_at INTO v_last_scan
    FROM public.ai_scan_logs
    WHERE user_id = p_user_id
    ORDER BY created_at DESC
    LIMIT 1;

    v_cooldown_sec := 0;
    IF v_last_scan IS NOT NULL THEN
        v_cooldown_sec := GREATEST(0, 60 - EXTRACT(EPOCH FROM (NOW() - v_last_scan))::INTEGER);
    END IF;

    IF v_cooldown_sec > 0 THEN
        can_scan := false;
        daily_used := v_daily_count;
        daily_limit := v_daily_limit;
        cooldown_remaining := v_cooldown_sec;
        risk_blocked := false;
        error_msg := '请求过于频繁，请等待' || v_cooldown_sec || '秒';
        RETURN NEXT;
        RETURN;
    END IF;

    can_scan := true;
    daily_used := v_daily_count;
    daily_limit := v_daily_limit;
    cooldown_remaining := 0;
    risk_blocked := false;
    error_msg := '';
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 4: 记录AI调用成本
-- ============================================================
CREATE OR REPLACE FUNCTION record_ai_cost(
    p_user_id UUID,
    p_cost_cny NUMERIC,
    p_request_type TEXT DEFAULT 'card_scan',
    p_model TEXT DEFAULT 'moonshot-v1-128k-vision-preview',
    p_input_tokens INTEGER DEFAULT 0,
    p_output_tokens INTEGER DEFAULT 0,
    p_cached BOOLEAN DEFAULT false,
    p_image_hash TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO public.ai_cost_logs (
        user_id, cost_cny, request_type, model,
        input_tokens, output_tokens, cached, image_hash
    ) VALUES (
        p_user_id, p_cost_cny, p_request_type, p_model,
        p_input_tokens, p_output_tokens, p_cached, p_image_hash
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 5: 检查用户AI成本预算
-- ============================================================
CREATE OR REPLACE FUNCTION check_ai_cost_budget(
    p_user_id UUID
) RETURNS TABLE(
    can_call BOOLEAN,
    today_cost NUMERIC,
    daily_limit NUMERIC,
    error_msg TEXT
) AS $$
DECLARE
    v_today_cost NUMERIC;
    v_limit NUMERIC;
BEGIN
    SELECT COALESCE(SUM(cost_cny), 0) INTO v_today_cost
    FROM public.ai_cost_logs
    WHERE user_id = p_user_id AND created_at::DATE = CURRENT_DATE;

    SELECT COALESCE(value::NUMERIC, 2.00) INTO v_limit
    FROM public.platform_config WHERE key = 'ai_daily_cost_limit_free';

    today_cost := v_today_cost;
    daily_limit := v_limit;
    can_call := v_today_cost < v_limit;
    error_msg := CASE WHEN NOT can_call THEN '今日AI成本预算已用尽' ELSE '' END;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 6: 交易频率检查（防互刷）
-- 同一 buyer+seller 当天不超过3次
-- ============================================================
CREATE OR REPLACE FUNCTION check_trade_frequency(
    p_buyer_id UUID,
    p_seller_id UUID
) RETURNS TABLE(
    can_trade BOOLEAN,
    today_count INTEGER,
    max_per_day INTEGER,
    error_msg TEXT
) AS $$
DECLARE
    v_count INTEGER;
    v_limit INTEGER;
    v_risk RECORD;
BEGIN
    -- 风控检查
    SELECT * INTO v_risk FROM public.user_risk_levels WHERE user_id = p_buyer_id;
    IF FOUND AND v_risk.risk_level >= 3 THEN
        can_trade := false;
        today_count := 0;
        max_per_day := 0;
        error_msg := '账号已被封禁';
        RETURN NEXT;
        RETURN;
    END IF;
    IF FOUND AND v_risk.risk_level = 2 AND COALESCE(v_risk.restricted_features, ARRAY[]::TEXT[]) @> ARRAY['trade'] THEN
        IF v_risk.restricted_until IS NULL OR v_risk.restricted_until > NOW() THEN
            can_trade := false;
            today_count := 0;
            max_per_day := 0;
            error_msg := '交易功能已被临时限制';
            RETURN NEXT;
            RETURN;
        END IF;
    END IF;

    -- 同一买卖双方今日交易次数
    SELECT COUNT(*) INTO v_count
    FROM public.trade_frequency_logs
    WHERE buyer_id = p_buyer_id AND seller_id = p_seller_id
      AND created_at::DATE = CURRENT_DATE;

    SELECT COALESCE(
        (SELECT value::INTEGER FROM public.platform_config WHERE key = 'trade_max_pair_per_day'),
        3
    ) INTO v_limit;

    today_count := v_count;
    max_per_day := v_limit;
    can_trade := v_count < v_limit;
    error_msg := CASE WHEN NOT can_trade THEN '今日与该卖家的交易次数已达上限' ELSE '' END;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 7: 记录交易日志（用于频率统计）
-- ============================================================
CREATE OR REPLACE FUNCTION log_trade_frequency(
    p_buyer_id UUID,
    p_seller_id UUID,
    p_consignment_id UUID,
    p_order_id UUID,
    p_card_name TEXT,
    p_amount NUMERIC,
    p_ip_address TEXT DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO public.trade_frequency_logs (
        buyer_id, seller_id, consignment_id, order_id,
        card_name, amount, ip_address
    ) VALUES (
        p_buyer_id, p_seller_id, p_consignment_id, p_order_id,
        p_card_name, p_amount, p_ip_address
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 8: 用户风控等级评估 & 更新（自动）
-- ============================================================
CREATE OR REPLACE FUNCTION evaluate_user_risk(
    p_user_id UUID
) RETURNS JSON AS $$
DECLARE
    v_risk RECORD;
    v_score INTEGER := 0;
    v_flags TEXT[] := ARRAY[]::TEXT[];
    v_new_level SMALLINT := 0;
    v_today_scans INTEGER;
    v_consecutive_scans INTEGER;
    v_today_points INTEGER;
    v_today_trades INTEGER;
    v_threshold_scans INTEGER;
    v_threshold_points INTEGER;
BEGIN
    -- 获取当前风控记录
    SELECT * INTO v_risk FROM public.user_risk_levels WHERE user_id = p_user_id;

    -- 读取阈值配置
    SELECT COALESCE(
        (SELECT value::INTEGER FROM public.platform_config WHERE key = 'risk_ai_consecutive_threshold'),
        10
    ) INTO v_threshold_scans;
    SELECT COALESCE(
        (SELECT value::INTEGER FROM public.platform_config WHERE key = 'risk_points_daily_threshold'),
        200
    ) INTO v_threshold_points;

    -- 今日AI扫描次数
    SELECT COUNT(*) INTO v_today_scans
    FROM public.ai_scan_logs
    WHERE user_id = p_user_id AND created_at::DATE = CURRENT_DATE;

    -- 今日积分增长
    SELECT COALESCE(SUM(POINTS), 0) INTO v_today_points
    FROM public.point_transactions
    WHERE user_id = p_user_id AND created_at::DATE = CURRENT_DATE AND points > 0;

    -- 今日交易次数
    SELECT COUNT(*) INTO v_today_trades
    FROM public.trade_frequency_logs
    WHERE buyer_id = p_user_id AND created_at::DATE = CURRENT_DATE;

    -- 风控评分逻辑
    -- AI扫描异常
    IF v_today_scans > v_threshold_scans THEN
        v_score := v_score + 30;
        v_flags := array_append(v_flags, 'ai_abuse');
    ELSIF v_today_scans > v_threshold_scans * 0.7 THEN
        v_score := v_score + 15;
        v_flags := array_append(v_flags, 'ai_high_freq');
    END IF;

    -- 积分异常
    IF v_today_points > v_threshold_points THEN
        v_score := v_score + 25;
        v_flags := array_append(v_flags, 'points_farm');
    END IF;

    -- 交易异常
    IF v_today_trades > 10 THEN
        v_score := v_score + 20;
        v_flags := array_append(v_flags, 'trade_shill');
    END IF;

    -- 确定风控等级
    IF v_score >= 60 THEN
        v_new_level := 2;
    ELSIF v_score >= 30 THEN
        v_new_level := 1;
    ELSE
        v_new_level := 0;
    END IF;

    -- 如果已有更高等级，不降级（需要人工审核降级）
    IF v_risk IS NOT NULL AND v_risk.risk_level > v_new_level THEN
        v_new_level := v_risk.risk_level;
    END IF;

    -- 确定限制功能
    DECLARE
        v_restrictions TEXT[] := ARRAY[]::TEXT[];
        v_restrict_until TIMESTAMP WITH TIME ZONE;
    BEGIN
        IF v_new_level = 2 THEN
            IF v_flags @> ARRAY['ai_abuse'] THEN
                v_restrictions := array_append(v_restrictions, 'ai_scan');
            END IF;
            IF v_flags @> ARRAY['trade_shill'] THEN
                v_restrictions := array_append(v_restrictions, 'trade');
            END IF;
            v_restrict_until := NOW() + INTERVAL '24 hours';
        END IF;

        -- Upsert风控记录
        INSERT INTO public.user_risk_levels (
            user_id, risk_level, risk_score, flags,
            restricted_features, restricted_until,
            last_evaluated_at, updated_at
        ) VALUES (
            p_user_id, v_new_level, v_score, v_flags,
            v_restrictions, v_restrict_until,
            NOW(), NOW()
        )
        ON CONFLICT (user_id) DO UPDATE SET
            risk_level = EXCLUDED.risk_level,
            risk_score = EXCLUDED.risk_score,
            flags = EXCLUDED.flags,
            restricted_features = EXCLUDED.restricted_features,
            restricted_until = EXCLUDED.restricted_until,
            last_evaluated_at = NOW(),
            updated_at = NOW();

        -- 记录风控事件
        IF v_score > 0 THEN
            INSERT INTO public.risk_events (user_id, event_type, severity, detail)
            VALUES (
                p_user_id,
                'risk_evaluation',
                CASE WHEN v_new_level >= 2 THEN 'critical' ELSE 'warning' END,
                json_build_object(
                    'score', v_score,
                    'level', v_new_level,
                    'flags', v_flags,
                    'today_scans', v_today_scans,
                    'today_points', v_today_points,
                    'today_trades', v_today_trades
                )
            );
        END IF;
    END;

    RETURN json_build_object(
        'user_id', p_user_id,
        'risk_level', v_new_level,
        'risk_score', v_score,
        'flags', v_flags,
        'today_scans', v_today_scans,
        'today_points', v_today_points,
        'today_trades', v_today_trades
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 9: 服务端签到（防客户端时间篡改）
-- 使用 CURRENT_DATE 保证服务端时间
-- ============================================================
CREATE OR REPLACE FUNCTION daily_signin(
    p_user_id UUID
) RETURNS JSON AS $$
DECLARE
    v_points RECORD;
    v_last_date DATE;
    v_streak INTEGER;
    v_points_award INTEGER;
    v_level_bonus INTEGER;
    v_today_exists INTEGER;
    v_risk RECORD;
BEGIN
    -- 风控检查
    SELECT * INTO v_risk FROM public.user_risk_levels WHERE user_id = p_user_id;
    IF FOUND AND v_risk.risk_level >= 3 THEN
        RETURN json_build_object('success', false, 'error', '账号已被封禁');
    END IF;
    IF FOUND AND v_risk.risk_level = 2 AND COALESCE(v_risk.restricted_features, ARRAY[]::TEXT[]) @> ARRAY['signin'] THEN
        IF v_risk.restricted_until IS NULL OR v_risk.restricted_until > NOW() THEN
            RETURN json_build_object('success', false, 'error', '签到功能已被临时限制');
        END IF;
    END IF;

    -- 获取用户积分记录
    SELECT * INTO v_points FROM public.user_points WHERE user_id = p_user_id;
    IF NOT FOUND THEN
        INSERT INTO public.user_points (user_id) VALUES (p_user_id) RETURNING * INTO v_points;
    END IF;

    -- 检查今日是否已签到（服务端时间 CURRENT_DATE）
    SELECT COUNT(*) INTO v_today_exists
    FROM public.daily_checkins
    WHERE user_id = p_user_id AND checkin_date = CURRENT_DATE;

    IF v_today_exists > 0 THEN
        RETURN json_build_object('success', false, 'error', '今日已签到，请明天再来', 'already_checked', true);
    END IF;

    -- 计算连续天数
    v_last_date := v_points.last_checkin_date;
    IF v_last_date = CURRENT_DATE - INTERVAL '1 day' THEN
        v_streak := COALESCE(v_points.checkin_streak, 0) + 1;
    ELSE
        v_streak := 1;
    END IF;

    -- 基础积分
    v_points_award := 5;
    IF v_streak >= 7 THEN
        v_points_award := v_points_award + 10;
    ELSIF v_streak >= 3 THEN
        v_points_award := v_points_award + 3;
    END IF;

    -- 等级加成
    SELECT COALESCE(daily_checkin_bonus, 0) INTO v_level_bonus
    FROM public.level_config WHERE level = COALESCE(v_points.level, 1);
    v_points_award := v_points_award + COALESCE(v_level_bonus, 0);

    -- 插入签到记录（触发器会自动更新积分和流水）
    INSERT INTO public.daily_checkins (user_id, checkin_date, points_awarded, streak_day)
    VALUES (p_user_id, CURRENT_DATE, v_points_award, v_streak);

    -- 重新读取最新积分
    SELECT current_points, checkin_streak INTO v_points
    FROM public.user_points WHERE user_id = p_user_id;

    RETURN json_build_object(
        'success', true,
        'points_awarded', v_points_award,
        'streak', v_streak,
        'total_points', v_points.current_points,
        'checkin_date', CURRENT_DATE
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 10: 获取用户风控状态（前端展示）
-- ============================================================
CREATE OR REPLACE FUNCTION get_user_risk_status(
    p_user_id UUID
) RETURNS JSON AS $$
DECLARE
    v_risk RECORD;
    v_today_scans INTEGER;
    v_today_cost NUMERIC;
    v_today_trades INTEGER;
    v_today_points INTEGER;
BEGIN
    SELECT * INTO v_risk FROM public.user_risk_levels WHERE user_id = p_user_id;

    -- 今日AI扫描
    SELECT COUNT(*) INTO v_today_scans
    FROM public.ai_scan_logs
    WHERE user_id = p_user_id AND created_at::DATE = CURRENT_DATE;

    -- 今日AI成本
    SELECT COALESCE(SUM(cost_cny), 0) INTO v_today_cost
    FROM public.ai_cost_logs
    WHERE user_id = p_user_id AND created_at::DATE = CURRENT_DATE;

    -- 今日交易
    SELECT COUNT(*) INTO v_today_trades
    FROM public.trade_frequency_logs
    WHERE buyer_id = p_user_id AND created_at::DATE = CURRENT_DATE;

    -- 今日积分增长
    SELECT COALESCE(SUM(points), 0) INTO v_today_points
    FROM public.point_transactions
    WHERE user_id = p_user_id AND created_at::DATE = CURRENT_DATE AND points > 0;

    RETURN json_build_object(
        'risk_level', COALESCE(v_risk.risk_level, 0),
        'risk_score', COALESCE(v_risk.risk_score, 0),
        'flags', COALESCE(v_risk.flags, ARRAY[]::TEXT[]),
        'restricted_features', COALESCE(v_risk.restricted_features, ARRAY[]::TEXT[]),
        'restricted_until', v_risk.restricted_until,
        'today_scans', v_today_scans,
        'today_cost', v_today_cost,
        'today_trades', v_today_trades,
        'today_points', v_today_points
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 11: 增强版购买（含防刷 + 幂等）
-- 替代 0012 中的 purchase_consignment，增加:
--   - 交易频率检查
--   - 幂等键
--   - 交易日志记录
--   - 风控等级检查
-- ============================================================
CREATE OR REPLACE FUNCTION purchase_consignment_safe(
    p_buyer_id UUID,
    p_consignment_id UUID,
    p_idempotency_key TEXT DEFAULT NULL,
    p_ip_address TEXT DEFAULT NULL
) RETURNS JSON AS $$
DECLARE
    v_consign RECORD;
    v_buyer_wallet RECORD;
    v_seller_wallet RECORD;
    v_total_amount NUMERIC;
    v_order_id UUID;
    v_order_no TEXT;
    v_today_count INTEGER;
    v_buyer_collection_id UUID;
    v_seller_collection_id UUID;
    v_fee_pct NUMERIC;
    v_platform_fee NUMERIC;
    v_seller_earnings NUMERIC;
    v_freq_check RECORD;
    v_risk RECORD;
    v_existing_order RECORD;
    v_trade_limit INTEGER;
BEGIN
    -- 0. 幂等检查
    IF p_idempotency_key IS NOT NULL THEN
        SELECT * INTO v_existing_order
        FROM public.orders
        WHERE idempotency_key = p_idempotency_key
        LIMIT 1;

        IF FOUND THEN
            RETURN json_build_object(
                'success', true,
                'idempotent', true,
                'order_id', v_existing_order.id,
                'order_no', v_existing_order.order_no,
                'message', '订单已存在(幂等返回)'
            );
        END IF;
    END IF;

    -- 1. 风控等级检查
    SELECT * INTO v_risk FROM public.user_risk_levels WHERE user_id = p_buyer_id;
    IF FOUND AND v_risk.risk_level >= 3 THEN
        RETURN json_build_object('success', false, 'error', '账号已被封禁，无法交易');
    END IF;
    IF FOUND AND v_risk.risk_level = 2 AND COALESCE(v_risk.restricted_features, ARRAY[]::TEXT[]) @> ARRAY['trade'] THEN
        IF v_risk.restricted_until IS NULL OR v_risk.restricted_until > NOW() THEN
            RETURN json_build_object('success', false, 'error', '交易功能已被临时限制');
        END IF;
    END IF;

    -- 2. 锁定寄售单
    SELECT * INTO v_consign
    FROM public.consignments
    WHERE id = p_consignment_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN json_build_object('success', false, 'error', '寄售单不存在');
    END IF;

    IF v_consign.status != 'active' THEN
        RETURN json_build_object('success', false, 'error', '该卡牌已售出或已下架');
    END IF;

    IF v_consign.seller_id = p_buyer_id THEN
        RETURN json_build_object('success', false, 'error', '不能购买自己的卡牌');
    END IF;

    -- 3. 交易频率检查（防互刷）
    SELECT * INTO v_freq_check
    FROM check_trade_frequency(p_buyer_id, v_consign.seller_id);

    IF NOT v_freq_check.can_trade THEN
        RETURN json_build_object('success', false, 'error', v_freq_check.error_msg);
    END IF;

    -- 4. 获取费率 & 计算金额
    v_fee_pct := COALESCE(v_consign.platform_fee_pct, 8.00);
    v_total_amount := v_consign.asking_price + COALESCE(v_consign.shipping_fee, 0);
    v_platform_fee := ROUND(v_consign.asking_price * v_fee_pct / 100, 2);
    v_seller_earnings := v_consign.asking_price - v_platform_fee;

    -- 5. 锁定买家钱包
    SELECT * INTO v_buyer_wallet
    FROM public.wallets
    WHERE user_id = p_buyer_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.wallets (user_id, balance) VALUES (p_buyer_id, 0) RETURNING * INTO v_buyer_wallet;
    END IF;

    IF v_buyer_wallet.balance < v_total_amount THEN
        RETURN json_build_object('success', false, 'error', '余额不足，请先充值',
            'required', v_total_amount, 'balance', v_buyer_wallet.balance);
    END IF;

    -- 6. 锁定卖家钱包
    SELECT * INTO v_seller_wallet
    FROM public.wallets
    WHERE user_id = v_consign.seller_id
    FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO public.wallets (user_id, balance) VALUES (v_consign.seller_id, 0) RETURNING * INTO v_seller_wallet;
    END IF;

    -- 7. 生成订单号
    SELECT COUNT(*) + 1 INTO v_today_count
    FROM public.orders
    WHERE created_at::date = CURRENT_DATE;
    v_order_no := 'CR' || TO_CHAR(CURRENT_DATE, 'YYYYMMDD') || LPAD(v_today_count::TEXT, 4, '0');

    -- 8. 创建订单（含幂等键 + IP）
    INSERT INTO public.orders (
        order_no, buyer_id, seller_id, consignment_id,
        item_price, shipping_fee, platform_fee, total_amount, seller_earnings,
        currency, status, paid_at, idempotency_key, ip_address
    ) VALUES (
        v_order_no, p_buyer_id, v_consign.seller_id, p_consignment_id,
        v_consign.asking_price, COALESCE(v_consign.shipping_fee, 0),
        v_platform_fee, v_total_amount, v_seller_earnings,
        'CNY', 'paid', NOW(), p_idempotency_key, p_ip_address
    ) RETURNING id INTO v_order_id;

    -- 9. 更新寄售单状态
    UPDATE public.consignments
    SET status = 'sold', sold_at = NOW(), updated_at = NOW()
    WHERE id = p_consignment_id;

    -- 10. 扣减买家钱包
    UPDATE public.wallets
    SET balance = balance - v_total_amount,
        total_spent = total_spent + v_total_amount,
        updated_at = NOW()
    WHERE user_id = p_buyer_id;

    INSERT INTO public.wallet_transactions (wallet_id, user_id, amount, balance_after, type, reference_id, reference_type, description)
    VALUES (v_buyer_wallet.id, p_buyer_id, -v_total_amount, v_buyer_wallet.balance - v_total_amount,
            'purchase', v_order_id, 'order', '购买 ' || v_consign.card_name);

    -- 11. 卖家收入
    UPDATE public.wallets
    SET balance = balance + v_seller_earnings,
        total_earned = total_earned + v_seller_earnings,
        updated_at = NOW()
    WHERE user_id = v_consign.seller_id;

    INSERT INTO public.wallet_transactions (wallet_id, user_id, amount, balance_after, type, reference_id, reference_type, description)
    VALUES (v_seller_wallet.id, v_consign.seller_id, v_seller_earnings, v_seller_wallet.balance + v_seller_earnings,
            'sale', v_order_id, 'order', '售出 ' || v_consign.card_name);

    -- 12. 平台手续费
    INSERT INTO public.platform_fees (order_id, consignment_id, fee_type, fee_amount, fee_pct, currency, description)
    VALUES (v_order_id, p_consignment_id, 'transaction', v_platform_fee, v_fee_pct, 'CNY',
            v_consign.card_name || ' 交易手续费');

    -- 13. 卖家库存减少
    IF v_consign.collection_id IS NOT NULL THEN
        v_seller_collection_id := v_consign.collection_id;
        UPDATE public.user_collections
        SET quantity = GREATEST(quantity - 1, 0),
            reserved_quantity = GREATEST(reserved_quantity - 1, 0),
            updated_at = NOW()
        WHERE id = v_seller_collection_id;
    END IF;

    -- 14. 买家库存增加
    SELECT id INTO v_buyer_collection_id
    FROM public.user_collections
    WHERE user_id = p_buyer_id
      AND card_name = v_consign.card_name
      AND COALESCE(series, '') = COALESCE(v_consign.series, '')
      AND COALESCE(rarity, 'N') = COALESCE(v_consign.rarity, 'N')
    LIMIT 1;

    IF FOUND THEN
        UPDATE public.user_collections
        SET quantity = quantity + 1,
            purchase_price = v_consign.asking_price,
            current_price = v_consign.asking_price,
            updated_at = NOW()
        WHERE id = v_buyer_collection_id;
    ELSE
        INSERT INTO public.user_collections (
            user_id, card_name, card_name_en, card_image,
            series, rarity, card_category, condition,
            purchase_price, current_price, quantity, source
        ) VALUES (
            p_buyer_id, v_consign.card_name, v_consign.card_name_en, v_consign.card_image,
            v_consign.series, v_consign.rarity, v_consign.card_category, v_consign.condition,
            v_consign.asking_price, v_consign.asking_price, 1, 'PURCHASE'
        );
    END IF;

    -- 15. 记录交易频率日志（用于防互刷统计）
    PERFORM log_trade_frequency(
        p_buyer_id, v_consign.seller_id, p_consignment_id, v_order_id,
        v_consign.card_name, v_total_amount, p_ip_address
    );

    -- 16. 异步评估风控（不阻塞交易）
    BEGIN
        PERFORM evaluate_user_risk(p_buyer_id);
    EXCEPTION WHEN OTHERS THEN
        -- 风控评估失败不影响交易
        NULL;
    END;

    RETURN json_build_object(
        'success', true,
        'order_id', v_order_id,
        'order_no', v_order_no,
        'total_amount', v_total_amount,
        'platform_fee', v_platform_fee,
        'seller_earnings', v_seller_earnings,
        'card_name', v_consign.card_name
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 五、定时清理过期缓存（通过 pg_cron，如可用）
-- ============================================================
-- 如果 Supabase 实例启用了 pg_cron 扩展:
-- SELECT cron.schedule('clean-ai-cache', '0 3 * * *', 'DELETE FROM public.ai_scan_cache WHERE expires_at < NOW()');
-- 否则可忽略，缓存表有 UNIQUE 约束会自动覆盖

-- ============================================================
-- 六、索引优化
-- ============================================================
-- 注意: CURRENT_DATE 是 STABLE 函数，不能用于索引 predicate
-- 改用普通索引，查询时 WHERE 条件仍可利用时间范围扫描
CREATE INDEX IF NOT EXISTS idx_ai_scan_logs_user_date ON public.ai_scan_logs(user_id, (created_at::DATE) DESC);
CREATE INDEX IF NOT EXISTS idx_trade_freq_date ON public.trade_frequency_logs(buyer_id, seller_id, (created_at::DATE) DESC);

COMMENT ON TABLE public.ai_scan_cache IS 'AI识卡结果缓存，7天TTL，同图不重复调用AI';
COMMENT ON TABLE public.ai_cost_logs IS 'AI调用成本记录，用于成本控制';
COMMENT ON TABLE public.user_risk_levels IS '用户风控等级: 0=正常, 1=高频, 2=风险, 3=封禁';
COMMENT ON TABLE public.risk_events IS '风控事件审计日志';
COMMENT ON TABLE public.trade_frequency_logs IS '交易频率日志，用于检测互刷行为';
COMMENT ON FUNCTION get_cached_scan_result IS '查询AI识卡缓存，命中则跳过AI调用';
COMMENT ON FUNCTION check_ai_rate_limit IS 'AI识卡频率检查: 每日上限 + 每分钟限频 + 风控拦截';
COMMENT ON FUNCTION evaluate_user_risk IS '自动评估用户风控等级并更新';
COMMENT ON FUNCTION daily_signin IS '服务端签到，防止客户端时间篡改';
COMMENT ON FUNCTION purchase_consignment_safe IS '增强版原子交易: 防刷+幂等+风控+频率检查';
