-- ============================================================
-- CardRealm MVP Phase 6: 用户增长 + 留存系统
-- ============================================================

-- ============================================================
-- 一、用户每日资产快照表
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_daily_snapshot (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    snapshot_date DATE NOT NULL DEFAULT CURRENT_DATE,
    total_asset NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_cost NUMERIC(14,2) NOT NULL DEFAULT 0,
    card_count INTEGER NOT NULL DEFAULT 0,
    rising_count INTEGER NOT NULL DEFAULT 0,
    falling_count INTEGER NOT NULL DEFAULT 0,
    change_percent NUMERIC(8,4) DEFAULT 0,
    change_amount NUMERIC(14,2) DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, snapshot_date)
);

CREATE INDEX IF NOT EXISTS idx_uds_user_date ON public.user_daily_snapshot(user_id, snapshot_date DESC);
CREATE INDEX IF NOT EXISTS idx_uds_date ON public.user_daily_snapshot(snapshot_date DESC);

ALTER TABLE public.user_daily_snapshot ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "uds_select_owner" ON public.user_daily_snapshot;
CREATE POLICY "uds_select_owner" ON public.user_daily_snapshot FOR SELECT
    USING (auth.uid() = user_id);

-- ============================================================
-- 二、价格监控/关注表（Watchlist）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.price_watchlist (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    card_name TEXT NOT NULL,
    series TEXT DEFAULT '',
    rarity TEXT DEFAULT 'N',
    watch_price NUMERIC(12,2),
    target_price NUMERIC(12,2),
    notify_on_rise BOOLEAN DEFAULT true,
    notify_on_fall BOOLEAN DEFAULT true,
    notify_pct_threshold NUMERIC(5,2) DEFAULT 5.0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, card_name, series, rarity)
);

CREATE INDEX IF NOT EXISTS idx_watchlist_user ON public.price_watchlist(user_id);
CREATE INDEX IF NOT EXISTS idx_watchlist_card ON public.price_watchlist(card_name);

ALTER TABLE public.price_watchlist ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "watchlist_select_owner" ON public.price_watchlist;
DROP POLICY IF EXISTS "watchlist_insert_owner" ON public.price_watchlist;
DROP POLICY IF EXISTS "watchlist_delete_owner" ON public.price_watchlist;
CREATE POLICY "watchlist_select_owner" ON public.price_watchlist FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "watchlist_insert_owner" ON public.price_watchlist FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "watchlist_delete_owner" ON public.price_watchlist FOR DELETE USING (auth.uid() = user_id);

-- ============================================================
-- 三、用户活动日志（用于推荐系统）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.user_activity_log (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    action TEXT NOT NULL CHECK (action IN ('scan','view','favorite','purchase','search','share')),
    target_type TEXT DEFAULT 'card' CHECK (target_type IN ('card','product','post','market')),
    target_id TEXT,
    card_name TEXT,
    series TEXT,
    category TEXT,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ual_user_time ON public.user_activity_log(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ual_action ON public.user_activity_log(action, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ual_card ON public.user_activity_log(card_name);

ALTER TABLE public.user_activity_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "ual_insert_owner" ON public.user_activity_log;
DROP POLICY IF EXISTS "ual_select_owner" ON public.user_activity_log;
CREATE POLICY "ual_insert_owner" ON public.user_activity_log FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "ual_select_owner" ON public.user_activity_log FOR SELECT USING (auth.uid() = user_id);

-- ============================================================
-- 四、平台每日增长统计
-- ============================================================
CREATE TABLE IF NOT EXISTS public.daily_growth_stats (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    stat_date DATE NOT NULL DEFAULT CURRENT_DATE,
    dau INTEGER DEFAULT 0,
    mau INTEGER DEFAULT 0,
    new_users INTEGER DEFAULT 0,
    total_asset_all NUMERIC(16,2) DEFAULT 0,
    total_asset_change NUMERIC(16,2) DEFAULT 0,
    total_trades INTEGER DEFAULT 0,
    trade_gmv NUMERIC(14,2) DEFAULT 0,
    ai_scan_count INTEGER DEFAULT 0,
    retention_d1_pct NUMERIC(5,2),
    retention_d7_pct NUMERIC(5,2),
    active_collection_users INTEGER DEFAULT 0,
    watchlist_users INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(stat_date)
);

CREATE INDEX IF NOT EXISTS idx_dgs_date ON public.daily_growth_stats(stat_date DESC);

ALTER TABLE public.daily_growth_stats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "dgs_select_all" ON public.daily_growth_stats;
CREATE POLICY "dgs_select_all" ON public.daily_growth_stats FOR SELECT TO authenticated USING (true);

-- ============================================================
-- 五、RPC: 记录用户每日资产快照
-- ============================================================
CREATE OR REPLACE FUNCTION take_user_daily_snapshot(
    p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_total_asset NUMERIC(14,2) := 0;
    v_total_cost NUMERIC(14,2) := 0;
    v_card_count INTEGER := 0;
    v_rising_count INTEGER := 0;
    v_falling_count INTEGER := 0;
    v_change_percent NUMERIC(8,4) := 0;
    v_change_amount NUMERIC(14,2) := 0;
    v_yesterday_asset NUMERIC(14,2);
    v_today DATE := CURRENT_DATE;
BEGIN
    -- 计算当前总资产
    SELECT
        COALESCE(SUM(COALESCE(cp.current_price, uc.current_price, uc.purchase_price, 0) * uc.quantity), 0),
        COALESCE(SUM(uc.purchase_price * uc.quantity), 0),
        COALESCE(SUM(uc.quantity), 0)
    INTO v_total_asset, v_total_cost, v_card_count
    FROM public.user_collections uc
    LEFT JOIN public.card_prices cp
        ON uc.card_name = cp.card_name
        AND COALESCE(uc.series, '') = COALESCE(cp.series, '')
        AND COALESCE(uc.rarity, 'N') = COALESCE(cp.rarity, 'N')
        AND cp.market = 'CN'
    WHERE uc.user_id = p_user_id;

    -- 上涨/下跌卡牌数
    SELECT
        COALESCE(SUM(CASE WHEN COALESCE(cp.change_percent, 0) > 0 THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN COALESCE(cp.change_percent, 0) < 0 THEN 1 ELSE 0 END), 0)
    INTO v_rising_count, v_falling_count
    FROM public.user_collections uc
    LEFT JOIN public.card_prices cp
        ON uc.card_name = cp.card_name
        AND COALESCE(uc.series, '') = COALESCE(cp.series, '')
        AND COALESCE(uc.rarity, 'N') = COALESCE(cp.rarity, 'N')
        AND cp.market = 'CN'
    WHERE uc.user_id = p_user_id;

    -- 获取昨日资产
    SELECT total_asset INTO v_yesterday_asset
    FROM public.user_daily_snapshot
    WHERE user_id = p_user_id AND snapshot_date = v_today - 1
    LIMIT 1;

    -- 计算涨跌
    IF v_yesterday_asset IS NOT NULL AND v_yesterday_asset > 0 THEN
        v_change_amount := v_total_asset - v_yesterday_asset;
        v_change_percent := ROUND((v_change_amount / v_yesterday_asset) * 100, 4);
    END IF;

    -- Upsert 快照
    INSERT INTO public.user_daily_snapshot (
        user_id, snapshot_date, total_asset, total_cost, card_count,
        rising_count, falling_count, change_percent, change_amount
    ) VALUES (
        p_user_id, v_today, v_total_asset, v_total_cost, v_card_count,
        v_rising_count, v_falling_count, v_change_percent, v_change_amount
    )
    ON CONFLICT (user_id, snapshot_date) DO UPDATE SET
        total_asset = EXCLUDED.total_asset,
        total_cost = EXCLUDED.total_cost,
        card_count = EXCLUDED.card_count,
        rising_count = EXCLUDED.rising_count,
        falling_count = EXCLUDED.falling_count,
        change_percent = EXCLUDED.change_percent,
        change_amount = EXCLUDED.change_amount;

    RETURN jsonb_build_object(
        'success', true,
        'total_asset', v_total_asset,
        'card_count', v_card_count,
        'rising_count', v_rising_count,
        'falling_count', v_falling_count,
        'change_percent', v_change_percent,
        'change_amount', v_change_amount
    );
END;
$$;

-- ============================================================
-- 六、RPC: 获取用户资产变化（今日 vs 昨日）
-- ============================================================
CREATE OR REPLACE FUNCTION get_user_asset_change(
    p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_today_snap public.user_daily_snapshot%ROWTYPE;
    v_yesterday_snap public.user_daily_snapshot%ROWTYPE;
    v_changed_cards_json JSONB;
BEGIN
    -- 尝试获取已有快照
    SELECT * INTO v_today_snap FROM public.user_daily_snapshot
    WHERE user_id = p_user_id AND snapshot_date = CURRENT_DATE
    LIMIT 1;

    -- 如果没有今天快照，实时计算
    IF NOT FOUND THEN
        -- 调用 snapshot RPC
        PERFORM take_user_daily_snapshot(p_user_id);
        SELECT * INTO v_today_snap FROM public.user_daily_snapshot
        WHERE user_id = p_user_id AND snapshot_date = CURRENT_DATE
        LIMIT 1;
    END IF;

    SELECT * INTO v_yesterday_snap FROM public.user_daily_snapshot
    WHERE user_id = p_user_id AND snapshot_date = CURRENT_DATE - 1
    LIMIT 1;

    -- 获取变化的卡牌（最多5张）
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'card_name', cp.card_name,
            'series', cp.series,
            'rarity', cp.rarity,
            'current_price', cp.current_price,
            'change_percent', cp.change_percent,
            'change_amount', cp.change_amount
        ) ORDER BY ABS(cp.change_percent) DESC
    ) FILTER (WHERE cp.card_name IS NOT NULL), '[]'::jsonb)
    INTO v_changed_cards_json
    FROM public.card_prices cp
    JOIN public.user_collections uc
        ON uc.card_name = cp.card_name
        AND COALESCE(uc.series, '') = COALESCE(cp.series, '')
        AND COALESCE(uc.rarity, 'N') = COALESCE(cp.rarity, 'N')
    WHERE uc.user_id = p_user_id
      AND cp.market = 'CN'
      AND ABS(COALESCE(cp.change_percent, 0)) > 0
    LIMIT 5;

    RETURN jsonb_build_object(
        'success', true,
        'today', jsonb_build_object(
            'total_asset', v_today_snap.total_asset,
            'card_count', v_today_snap.card_count,
            'rising_count', v_today_snap.rising_count,
            'falling_count', v_today_snap.falling_count
        ),
        'change', jsonb_build_object(
            'percent', COALESCE(v_today_snap.change_percent, 0),
            'amount', COALESCE(v_today_snap.change_amount, 0),
            'yesterday_asset', v_yesterday_snap.total_asset
        ),
        'changed_cards', v_changed_cards_json,
        'message', CASE
            WHEN v_today_snap.change_percent > 0 THEN '📈 你的资产今天上涨了 +' || ROUND(v_today_snap.change_percent, 2)::TEXT || '%'
            WHEN v_today_snap.change_percent < 0 THEN '📉 你的资产今天下跌了 ' || ROUND(v_today_snap.change_percent, 2)::TEXT || '%'
            ELSE '你的资产今天没有变化'
        END
    );
END;
$$;

-- ============================================================
-- 七、RPC: 加入价格监控
-- ============================================================
CREATE OR REPLACE FUNCTION add_to_watchlist(
    p_user_id UUID,
    p_card_name TEXT,
    p_series TEXT DEFAULT '',
    p_rarity TEXT DEFAULT 'N',
    p_target_price NUMERIC DEFAULT NULL,
    p_notify_pct NUMERIC DEFAULT 5.0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_watch_id UUID;
    v_current_price NUMERIC(12,2);
BEGIN
    -- 查当前价格
    SELECT current_price INTO v_current_price
    FROM public.card_prices
    WHERE card_name = p_card_name
      AND COALESCE(series, '') = COALESCE(p_series, '')
      AND COALESCE(rarity, 'N') = COALESCE(p_rarity, 'N')
      AND market = 'CN'
    LIMIT 1;

    INSERT INTO public.price_watchlist (
        user_id, card_name, series, rarity,
        watch_price, target_price, notify_pct_threshold
    ) VALUES (
        p_user_id, p_card_name, p_series, p_rarity,
        v_current_price, COALESCE(p_target_price, v_current_price),
        COALESCE(p_notify_pct, 5.0)
    )
    ON CONFLICT (user_id, card_name, series, rarity) DO UPDATE SET
        watch_price = COALESCE(v_current_price, public.price_watchlist.watch_price),
        target_price = COALESCE(p_target_price, public.price_watchlist.target_price),
        notify_pct_threshold = COALESCE(p_notify_pct, public.price_watchlist.notify_pct_threshold)
    RETURNING id INTO v_watch_id;

    RETURN jsonb_build_object(
        'success', true,
        'watch_id', v_watch_id,
        'card_name', p_card_name,
        'current_price', v_current_price
    );
END;
$$;

-- ============================================================
-- 八、RPC: 检查监控提醒
-- ============================================================
CREATE OR REPLACE FUNCTION check_watch_alerts(
    p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_alerts JSONB;
BEGIN
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'watch_id', pw.id,
            'card_name', pw.card_name,
            'series', pw.series,
            'rarity', pw.rarity,
            'watch_price', pw.watch_price,
            'current_price', cp.current_price,
            'change_percent', cp.change_percent,
            'change_amount', cp.change_amount,
            'alert_type', CASE
                WHEN cp.change_percent >= pw.notify_pct_threshold THEN 'surge'
                WHEN cp.change_percent <= -pw.notify_pct_threshold THEN 'drop'
                ELSE 'info'
            END
        ) ORDER BY ABS(COALESCE(cp.change_percent, 0)) DESC
    ) FILTER (WHERE pw.id IS NOT NULL), '[]'::jsonb)
    INTO v_alerts
    FROM public.price_watchlist pw
    LEFT JOIN public.card_prices cp
        ON pw.card_name = cp.card_name
        AND COALESCE(pw.series, '') = COALESCE(cp.series, '')
        AND COALESCE(pw.rarity, 'N') = COALESCE(cp.rarity, 'N')
        AND cp.market = 'CN'
    WHERE pw.user_id = p_user_id
      AND cp.current_price IS NOT NULL
      AND ABS(COALESCE(cp.change_percent, 0)) > 0;

    RETURN jsonb_build_object(
        'success', true,
        'alert_count', COALESCE(jsonb_array_length(v_alerts), 0),
        'alerts', v_alerts,
        'has_surge', EXISTS (
            SELECT 1 FROM jsonb_array_elements(v_alerts) a
            WHERE a->>'alert_type' = 'surge'
        )
    );
END;
$$;

-- ============================================================
-- 九、RPC: 平台增长统计
-- ============================================================
CREATE OR REPLACE FUNCTION get_daily_growth_stats(
    p_days INTEGER DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_today DATE := CURRENT_DATE;
    v_today_stats JSONB;
    v_trend JSONB;
    v_dau_today INTEGER;
    v_mau_today INTEGER;
    v_trades_today INTEGER;
    v_scans_today INTEGER;
    v_asset_total NUMERIC(16,2);
    v_asset_7d_ago NUMERIC(16,2);
    v_new_users_today INTEGER;
    v_retention_d1 NUMERIC(5,2);
    v_retention_d7 NUMERIC(5,2);
    v_active_collection_users INTEGER;
    v_watchlist_users INTEGER;
BEGIN
    -- 今日 DAU（24小时内登录用户）
    SELECT COUNT(DISTINCT user_id) INTO v_dau_today
    FROM public.user_activity_log
    WHERE created_at >= v_today::TIMESTAMPTZ
      AND created_at < (v_today + 1)::TIMESTAMPTZ;

    -- MAU（30天内活跃用户）
    SELECT COUNT(DISTINCT user_id) INTO v_mau_today
    FROM public.user_activity_log
    WHERE created_at >= (v_today - 30)::TIMESTAMPTZ;

    -- 今日交易数
    SELECT COUNT(*) INTO v_trades_today
    FROM public.orders
    WHERE created_at >= v_today::TIMESTAMPTZ
      AND created_at < (v_today + 1)::TIMESTAMPTZ;

    -- 今日 AI 扫描数
    SELECT COUNT(*) INTO v_scans_today
    FROM public.ai_scan_logs
    WHERE created_at >= v_today::TIMESTAMPTZ
      AND created_at < (v_today + 1)::TIMESTAMPTZ;

    -- 平台总资产
    SELECT COALESCE(SUM(total_asset), 0) INTO v_asset_total
    FROM public.user_daily_snapshot
    WHERE snapshot_date = v_today;

    -- 7天前总资产
    SELECT COALESCE(SUM(total_asset), 0) INTO v_asset_7d_ago
    FROM public.user_daily_snapshot
    WHERE snapshot_date = v_today - (p_days - 1);

    -- 今日新用户
    SELECT COUNT(*) INTO v_new_users_today
    FROM auth.users
    WHERE created_at >= v_today::TIMESTAMPTZ
      AND created_at < (v_today + 1)::TIMESTAMPTZ;

    -- 有资产快照的用户数
    SELECT COUNT(DISTINCT user_id) INTO v_active_collection_users
    FROM public.user_daily_snapshot
    WHERE snapshot_date = v_today
      AND total_asset > 0;

    -- 使用监控的用户数
    SELECT COUNT(DISTINCT user_id) INTO v_watchlist_users
    FROM public.price_watchlist;

    -- D1 留存（昨日新用户中今天回来的）
    SELECT
        CASE WHEN COUNT(*) > 0
        THEN ROUND(
            COUNT(*) FILTER (WHERE EXISTS (
                SELECT 1 FROM public.user_activity_log ual
                WHERE ual.user_id = au.id
                  AND ual.created_at >= v_today::TIMESTAMPTZ
                  AND ual.created_at < (v_today + 1)::TIMESTAMPTZ
            ))::NUMERIC / COUNT(*)::NUMERIC * 100, 2)
        ELSE 0 END
    INTO v_retention_d1
    FROM auth.users au
    WHERE au.created_at >= (v_today - 1)::TIMESTAMPTZ
      AND au.created_at < v_today::TIMESTAMPTZ;

    -- D7 留存（7天前新用户中今天回来的）
    SELECT
        CASE WHEN COUNT(*) > 0
        THEN ROUND(
            COUNT(*) FILTER (WHERE EXISTS (
                SELECT 1 FROM public.user_activity_log ual
                WHERE ual.user_id = au.id
                  AND ual.created_at >= v_today::TIMESTAMPTZ
                  AND ual.created_at < (v_today + 1)::TIMESTAMPTZ
            ))::NUMERIC / COUNT(*)::NUMERIC * 100, 2)
        ELSE 0 END
    INTO v_retention_d7
    FROM auth.users au
    WHERE au.created_at >= (v_today - 7)::TIMESTAMPTZ
      AND au.created_at < (v_today - 6)::TIMESTAMPTZ;

    -- 趋势数据
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'date', dgs.stat_date,
            'dau', dgs.dau,
            'trades', dgs.total_trades,
            'scans', dgs.ai_scan_count,
            'gmv', dgs.trade_gmv
        ) ORDER BY dgs.stat_date
    ), '[]'::jsonb) INTO v_trend
    FROM public.daily_growth_stats dgs
    WHERE dgs.stat_date >= v_today - (p_days - 1);

    -- 更新统计表
    INSERT INTO public.daily_growth_stats (
        stat_date, dau, mau, new_users,
        total_asset_all, total_asset_change,
        total_trades, trade_gmv,
        ai_scan_count,
        retention_d1_pct, retention_d7_pct,
        active_collection_users, watchlist_users
    ) VALUES (
        v_today, v_dau_today, v_mau_today, v_new_users_today,
        v_asset_total, v_asset_total - v_asset_7d_ago,
        v_trades_today, 0,
        v_scans_today,
        v_retention_d1, v_retention_d7,
        v_active_collection_users, v_watchlist_users
    )
    ON CONFLICT (stat_date) DO UPDATE SET
        dau = EXCLUDED.dau,
        mau = EXCLUDED.mau,
        new_users = EXCLUDED.new_users,
        total_asset_all = EXCLUDED.total_asset_all,
        total_asset_change = EXCLUDED.total_asset_change,
        total_trades = EXCLUDED.total_trades,
        ai_scan_count = EXCLUDED.ai_scan_count,
        retention_d1_pct = EXCLUDED.retention_d1_pct,
        retention_d7_pct = EXCLUDED.retention_d7_pct,
        active_collection_users = EXCLUDED.active_collection_users,
        watchlist_users = EXCLUDED.watchlist_users;

    RETURN jsonb_build_object(
        'success', true,
        'today', jsonb_build_object(
            'dau', v_dau_today,
            'mau', v_mau_today,
            'new_users', v_new_users_today,
            'total_trades', v_trades_today,
            'ai_scans', v_scans_today,
            'total_asset', v_asset_total,
            'asset_change_7d', v_asset_total - v_asset_7d_ago,
            'retention_d1', v_retention_d1,
            'retention_d7', v_retention_d7,
            'active_collection_users', v_active_collection_users,
            'watchlist_users', v_watchlist_users
        ),
        'trend', v_trend
    );
END;
$$;

-- ============================================================
-- 十、RPC: 热门上涨卡牌
-- ============================================================
CREATE OR REPLACE FUNCTION get_hot_rising_cards(
    p_limit INTEGER DEFAULT 10,
    p_market TEXT DEFAULT 'CN'
)
RETURNS TABLE(
    card_name TEXT,
    series TEXT,
    rarity TEXT,
    current_price NUMERIC(12,2),
    change_percent NUMERIC(8,4),
    change_amount NUMERIC(12,2),
    hot_score BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT
        cp.card_name,
        cp.series,
        cp.rarity,
        cp.current_price,
        cp.change_percent,
        cp.change_amount,
        COALESCE((
            SELECT COUNT(*) FROM public.user_collections uc
            WHERE uc.card_name = cp.card_name
        ), 0) AS hot_score
    FROM public.card_prices cp
    WHERE cp.market = p_market
      AND cp.current_price > 0
      AND cp.change_percent > 0
    ORDER BY cp.change_percent DESC, hot_score DESC
    LIMIT p_limit;
$$;

-- ============================================================
-- 十一、RPC: 用户个性化推荐（轻量版）
-- ============================================================
CREATE OR REPLACE FUNCTION get_user_recommendations(
    p_user_id UUID,
    p_limit INTEGER DEFAULT 6
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_interests TEXT[];
    v_recommendations JSONB;
BEGIN
    -- 收集用户兴趣：来自collections + activity + favorites
    SELECT ARRAY_AGG(DISTINCT uc.series) FILTER (WHERE uc.series IS NOT NULL AND uc.series != '')
    INTO v_interests
    FROM public.user_collections uc
    WHERE uc.user_id = p_user_id
    LIMIT 10;

    -- 如果没有收藏数据，从活动日志获取
    IF v_interests IS NULL OR array_length(v_interests, 1) IS NULL THEN
        SELECT ARRAY_AGG(DISTINCT ual.series) FILTER (WHERE ual.series IS NOT NULL AND ual.series != '')
        INTO v_interests
        FROM public.user_activity_log ual
        WHERE ual.user_id = p_user_id
        LIMIT 10;
    END IF;

    -- 推荐：同系列热门卡牌（排除已收藏的）
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'card_name', cp.card_name,
            'series', cp.series,
            'rarity', cp.rarity,
            'current_price', cp.current_price,
            'change_percent', cp.change_percent,
            'reason', '同系列热门'
        ) ORDER BY cp.change_percent DESC NULLS LAST
    ) FILTER (WHERE cp.card_name IS NOT NULL), '[]'::jsonb)
    INTO v_recommendations
    FROM public.card_prices cp
    WHERE cp.market = 'CN'
      AND cp.current_price > 0
      AND cp.change_percent > 0
      AND (
          v_interests IS NOT NULL
          AND array_length(v_interests, 1) IS NOT NULL
          AND cp.series = ANY(v_interests)
      )
      AND NOT EXISTS (
          SELECT 1 FROM public.user_collections uc
          WHERE uc.user_id = p_user_id
            AND uc.card_name = cp.card_name
      )
    LIMIT p_limit;

    -- 如果基于兴趣没有结果，返回全局热门
    IF v_recommendations IS NULL OR jsonb_array_length(v_recommendations) = 0 THEN
        SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
                'card_name', cp.card_name,
                'series', cp.series,
                'rarity', cp.rarity,
                'current_price', cp.current_price,
                'change_percent', cp.change_percent,
                'reason', '全局热门上涨'
            ) ORDER BY cp.change_percent DESC NULLS LAST
        ) FILTER (WHERE cp.card_name IS NOT NULL), '[]'::jsonb)
        INTO v_recommendations
        FROM public.card_prices cp
        WHERE cp.market = 'CN'
          AND cp.current_price > 0
          AND cp.change_percent > 0
          AND NOT EXISTS (
              SELECT 1 FROM public.user_collections uc
              WHERE uc.user_id = p_user_id
                AND uc.card_name = cp.card_name
          )
        LIMIT p_limit;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'interests', v_interests,
        'recommendations', COALESCE(v_recommendations, '[]'::jsonb)
    );
END;
$$;

-- ============================================================
-- 十二、RPC: 批量种子快照（模拟每日任务）
-- ============================================================
CREATE OR REPLACE FUNCTION seed_daily_snapshots(
    p_days INTEGER DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_user RECORD;
    v_total INTEGER := 0;
    v_date DATE;
    v_d INTEGER;
    v_asset NUMERIC(14,2);
BEGIN
    -- 遍历所有有收藏的用户
    FOR v_user IN SELECT DISTINCT user_id FROM public.user_collections LOOP
        -- 为过去 N 天生成快照（每天波动 ±1-8%）
        FOR v_d IN REVERSE p_days..0 LOOP
            v_date := CURRENT_DATE - v_d;

            -- 计算当天总资产（基于当前价格 + 波动）
            SELECT COALESCE(SUM(
                COALESCE(cp.current_price, uc.purchase_price, 0) * uc.quantity
                * (1 + (RANDOM() * 0.16 - 0.08)) -- ±8% 随机波动
            ), 0) INTO v_asset
            FROM public.user_collections uc
            LEFT JOIN public.card_prices cp
                ON uc.card_name = cp.card_name
                AND COALESCE(uc.series, '') = COALESCE(cp.series, '')
                AND COALESCE(uc.rarity, 'N') = COALESCE(cp.rarity, 'N')
                AND cp.market = 'CN'
            WHERE uc.user_id = v_user.user_id;

            INSERT INTO public.user_daily_snapshot (
                user_id, snapshot_date, total_asset, total_cost, card_count
            ) VALUES (
                v_user.user_id, v_date, v_asset, 0, 1
            )
            ON CONFLICT (user_id, snapshot_date) DO NOTHING;

            v_total := v_total + 1;
        END LOOP;
    END LOOP;

    -- 更新今日快照为实际值
    FOR v_user IN SELECT DISTINCT user_id FROM public.user_collections LOOP
        PERFORM take_user_daily_snapshot(v_user.user_id);
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'snapshots_seeded', v_total,
        'message', '已生成 ' || v_total || ' 条历史快照'
    );
END;
$$;

-- ============================================================
-- 十三、种子数据（历史增长统计）
-- ============================================================
INSERT INTO public.daily_growth_stats (stat_date, dau, mau, new_users, total_trades, ai_scan_count, retention_d1_pct, retention_d7_pct)
VALUES
    (CURRENT_DATE - 6, 12, 45, 3, 5, 18, 42.0, 25.0),
    (CURRENT_DATE - 5, 15, 48, 2, 7, 22, 40.0, 28.0),
    (CURRENT_DATE - 4, 18, 52, 4, 8, 25, 45.0, 30.0),
    (CURRENT_DATE - 3, 20, 55, 3, 10, 30, 48.0, 32.0),
    (CURRENT_DATE - 2, 22, 58, 5, 12, 35, 50.0, 35.0),
    (CURRENT_DATE - 1, 25, 60, 4, 8, 28, 52.0, 38.0)
ON CONFLICT (stat_date) DO NOTHING;

-- ============================================================
-- 注释
-- ============================================================
COMMENT ON TABLE public.user_daily_snapshot IS '用户每日资产快照（驱动回访 + 资产曲线）';
COMMENT ON TABLE public.price_watchlist IS '用户价格监控列表（卡牌级关注提醒）';
COMMENT ON TABLE public.user_activity_log IS '用户行为日志（推荐系统数据源）';
COMMENT ON TABLE public.daily_growth_stats IS '平台每日增长指标（DAU/留存/交易/扫描）';
COMMENT ON FUNCTION take_user_daily_snapshot IS '记录用户当日资产快照，自动计算涨跌';
COMMENT ON FUNCTION get_user_asset_change IS '获取用户今日 vs 昨日资产变化 + 变动卡牌';
COMMENT ON FUNCTION add_to_watchlist IS '将卡牌加入价格监控列表';
COMMENT ON FUNCTION check_watch_alerts IS '检查监控列表中的价格变动提醒';
COMMENT ON FUNCTION get_daily_growth_stats IS '平台增长指标（DAU/MAU/留存/交易/扫描）';
COMMENT ON FUNCTION get_hot_rising_cards IS '当日热门上涨卡牌（按涨幅排序）';
COMMENT ON FUNCTION get_user_recommendations IS '基于用户兴趣的轻量个性化推荐';
COMMENT ON FUNCTION seed_daily_snapshots IS '批量生成历史快照数据（演示/测试用）';
