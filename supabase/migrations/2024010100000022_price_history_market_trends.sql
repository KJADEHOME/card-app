-- =====================================================================
-- 0022: price_history 市场趋势系统 — daily_price / 7d avg / volatility
--
-- 目标：从"当前值系统"升级为真正的"市场行情系统"
--
-- 升级内容:
--   1. price_history 新增 daily_price / change_percent / series / rarity
--   2. 部分唯一索引 (card_name, series, rarity, market, date) WHERE daily_price IS NOT NULL
--   3. take_daily_price_snapshot() — 每日快照 card_market.final_price
--   4. get_card_price_trend() — 单卡趋势（daily_price + 7d_avg + volatility）
--   5. get_market_volatility_ranking() — 全市场波动率排行
--   6. get_trending_cards() — 涨跌幅 TOP
--   7. get_market_heat_index() — 市场热度指数
--
-- 计算公式:
--   daily_return = (P_t - P_{t-1}) / P_{t-1}
--   7d_avg = AVG(daily_price) OVER last 7 days
--   volatility_7d = STDDEV(daily_return) OVER last 7 days  (标准差)
--   volatility_pct = volatility * 100                       (百分比形式)
-- =====================================================================

-- =====================================================================
-- 一、升级 price_history 表结构
-- =====================================================================

ALTER TABLE public.price_history ADD COLUMN IF NOT EXISTS series TEXT DEFAULT '';
ALTER TABLE public.price_history ADD COLUMN IF NOT EXISTS rarity TEXT DEFAULT 'N';
ALTER TABLE public.price_history ADD COLUMN IF NOT EXISTS daily_price NUMERIC(12,2);
ALTER TABLE public.price_history ADD COLUMN IF NOT EXISTS price_source TEXT;
ALTER TABLE public.price_history ADD COLUMN IF NOT EXISTS change_percent NUMERIC(8,2) DEFAULT 0;

ALTER TABLE public.price_history ALTER COLUMN card_id DROP NOT NULL;
ALTER TABLE public.price_history ALTER COLUMN card_category SET DEFAULT 'other';

CREATE INDEX IF NOT EXISTS idx_price_history_trend
    ON public.price_history(card_name, series, rarity, market, date DESC);

-- 部分唯一索引：同一张卡同一天只有一条 daily_price 快照
CREATE UNIQUE INDEX IF NOT EXISTS idx_price_history_daily_unique
    ON public.price_history (card_name, series, rarity, market, date)
    WHERE daily_price IS NOT NULL;

COMMENT ON COLUMN public.price_history.daily_price IS '系统每日定价快照 = card_market.final_price（收盘价）';
COMMENT ON COLUMN public.price_history.change_percent IS '当日涨跌幅 = (今日daily_price - 昨日daily_price) / 昨日daily_price * 100';
COMMENT ON COLUMN public.price_history.price_source IS '当日定价来源 live/market/ai';

-- =====================================================================
-- 二、每日价格快照 RPC
-- =====================================================================
CREATE OR REPLACE FUNCTION public.take_daily_price_snapshot(
    p_market TEXT DEFAULT 'CN'
) RETURNS TABLE(
    cards_snapshotted INTEGER,
    new_entries INTEGER,
    updated_entries INTEGER
) AS $$
DECLARE
    v_total INTEGER := 0;
    v_new INTEGER := 0;
    v_updated INTEGER := 0;
    v_today DATE := CURRENT_DATE;
BEGIN
    INSERT INTO public.price_history (
        card_id, card_name, card_category,
        series, rarity,
        daily_price, price_source,
        change_percent,
        currency, market, date
    )
    SELECT
        NULL,
        cm.card_name,
        cm.card_category,
        cm.series,
        cm.rarity,
        cm.final_price,
        cm.price_source,
        CASE
            WHEN prev.daily_price IS NOT NULL AND prev.daily_price > 0
            THEN ROUND((cm.final_price - prev.daily_price) / prev.daily_price * 100, 2)
            ELSE 0
        END,
        'CNY',
        cm.market,
        v_today
    FROM public.card_market cm
    LEFT JOIN public.price_history prev
        ON prev.card_name = cm.card_name
        AND prev.series = cm.series
        AND prev.rarity = cm.rarity
        AND prev.market = cm.market
        AND prev.daily_price IS NOT NULL
        AND prev.date = (
            SELECT MAX(ph.date) FROM public.price_history ph
            WHERE ph.card_name = cm.card_name
              AND ph.series = cm.series
              AND ph.rarity = cm.rarity
              AND ph.market = cm.market
              AND ph.daily_price IS NOT NULL
              AND ph.date < v_today
        )
    WHERE cm.market = p_market
      AND cm.final_price > 0
    ON CONFLICT (card_name, series, rarity, market, date) WHERE daily_price IS NOT NULL
    DO UPDATE SET
        daily_price = EXCLUDED.daily_price,
        price_source = EXCLUDED.price_source,
        change_percent = EXCLUDED.change_percent;

    GET DIAGNOSTICS v_total = ROW_COUNT;

    SELECT
        COUNT(*) FILTER (WHERE created_at >= v_today::timestamp),
        COUNT(*) FILTER (WHERE created_at < v_today::timestamp)
    INTO v_new, v_updated
    FROM public.price_history
    WHERE date = v_today AND daily_price IS NOT NULL AND market = p_market;

    cards_snapshotted := v_total;
    new_entries := v_new;
    updated_entries := v_updated;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.take_daily_price_snapshot(TEXT) IS
'每日快照：将 card_market.final_price 写入 price_history.daily_price，并计算与前日涨跌幅';

-- =====================================================================
-- 三、单卡价格趋势 RPC
--    返回：daily_price 序列 + 7日均价 + 30日均价 + 7日/30日波动率
--    注意：CTE 中所有列使用 ph. 前缀 + pd_ 别名，避免 PL/pgSQL 变量冲突
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_card_price_trend(
    p_card_name TEXT,
    p_series TEXT DEFAULT '',
    p_rarity TEXT DEFAULT 'N',
    p_market TEXT DEFAULT 'CN',
    p_days INTEGER DEFAULT 30
) RETURNS TABLE(
    trend_date DATE,
    daily_price NUMERIC,
    change_percent NUMERIC,
    price_source TEXT,
    avg_7d NUMERIC,
    avg_30d NUMERIC,
    volatility_7d NUMERIC,
    volatility_30d NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH price_data AS (
        SELECT
            ph.date AS pd_date,
            ph.daily_price AS pd_price,
            ph.change_percent AS pd_change,
            ph.price_source AS pd_source,
            ph.daily_price / LAG(ph.daily_price) OVER (ORDER BY ph.date) - 1 AS pd_return
        FROM public.price_history ph
        WHERE ph.card_name = p_card_name
          AND ph.series = p_series
          AND ph.rarity = p_rarity
          AND ph.market = p_market
          AND ph.daily_price IS NOT NULL
          AND ph.date >= CURRENT_DATE - p_days
    ),
    enriched AS (
        SELECT
            pd_date,
            pd_price,
            pd_change,
            pd_source,
            pd_return,
            AVG(pd_price) OVER (ORDER BY pd_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS e_avg7,
            AVG(pd_price) OVER (ORDER BY pd_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS e_avg30,
            STDDEV(pd_return) OVER (ORDER BY pd_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS e_vol7,
            STDDEV(pd_return) OVER (ORDER BY pd_date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW) AS e_vol30
        FROM price_data
    )
    SELECT
        e.pd_date,
        ROUND(e.pd_price, 2),
        e.pd_change,
        e.pd_source,
        ROUND(e.e_avg7, 2),
        ROUND(e.e_avg30, 2),
        ROUND(e.e_vol7 * 100, 2),
        ROUND(e.e_vol30 * 100, 2)
    FROM enriched e
    ORDER BY e.pd_date;

    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_card_price_trend(TEXT, TEXT, TEXT, TEXT, INTEGER) IS
'单卡价格趋势：返回 daily_price + 7日均价 + 30日均价 + 7日/30日波动率';

-- =====================================================================
-- 四、全市场波动率排行 RPC
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_market_volatility_ranking(
    p_market TEXT DEFAULT 'CN',
    p_days INTEGER DEFAULT 7,
    p_limit INTEGER DEFAULT 20
) RETURNS TABLE(
    card_name TEXT,
    series TEXT,
    rarity TEXT,
    latest_price NUMERIC,
    avg_price NUMERIC,
    volatility NUMERIC,
    max_price NUMERIC,
    min_price NUMERIC,
    price_range_percent NUMERIC,
    data_points INTEGER
) AS $$
BEGIN
    RETURN QUERY
    WITH price_data AS (
        SELECT
            ph.card_name AS pd_name,
            ph.series AS pd_series,
            ph.rarity AS pd_rarity,
            ph.daily_price AS pd_price,
            ph.daily_price / LAG(ph.daily_price) OVER (
                PARTITION BY ph.card_name, ph.series, ph.rarity
                ORDER BY ph.date
            ) - 1 AS pd_return
        FROM public.price_history ph
        WHERE ph.market = p_market
          AND ph.daily_price IS NOT NULL
          AND ph.date >= CURRENT_DATE - p_days
    ),
    stats AS (
        SELECT DISTINCT
            pd_name,
            pd_series,
            pd_rarity,
            LAST_VALUE(pd_price) OVER w AS s_latest,
            AVG(pd_price) OVER w AS s_avg,
            STDDEV(pd_return) OVER w AS s_vol,
            MAX(pd_price) OVER w AS s_max,
            MIN(pd_price) OVER w AS s_min,
            COUNT(*) OVER w AS s_pts
        FROM price_data
        WINDOW w AS (PARTITION BY pd_name, pd_series, pd_rarity)
    )
    SELECT
        s.pd_name,
        s.pd_series,
        s.pd_rarity,
        ROUND(s.s_latest, 2),
        ROUND(s.s_avg, 2),
        ROUND(s.s_vol * 100, 2),
        ROUND(s.s_max, 2),
        ROUND(s.s_min, 2),
        CASE WHEN s.s_min > 0 THEN ROUND((s.s_max - s.s_min) / s.s_min * 100, 2) ELSE 0 END,
        s.s_pts::INTEGER
    FROM stats s
    WHERE s.s_pts >= 2
    ORDER BY s.s_vol DESC NULLS LAST
    LIMIT p_limit;

    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_market_volatility_ranking(TEXT, INTEGER, INTEGER) IS
'全市场波动率排行：返回波动率最高的卡牌，含最新价/均价/最高最低价/振幅';

-- =====================================================================
-- 五、涨跌幅 TOP RPC
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_trending_cards(
    p_market TEXT DEFAULT 'CN',
    p_direction TEXT DEFAULT 'both',
    p_limit INTEGER DEFAULT 10
) RETURNS TABLE(
    card_name TEXT,
    series TEXT,
    rarity TEXT,
    today_price NUMERIC,
    yesterday_price NUMERIC,
    change_percent NUMERIC,
    price_source TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH today_data AS (
        SELECT
            ph.card_name AS td_name,
            ph.series AS td_series,
            ph.rarity AS td_rarity,
            ph.daily_price AS td_price,
            ph.change_percent AS td_change,
            ph.price_source AS td_source
        FROM public.price_history ph
        WHERE ph.market = p_market
          AND ph.daily_price IS NOT NULL
          AND ph.date = CURRENT_DATE
    ),
    yesterday_data AS (
        SELECT
            ph.card_name AS yd_name,
            ph.series AS yd_series,
            ph.rarity AS yd_rarity,
            ph.daily_price AS yd_price
        FROM public.price_history ph
        WHERE ph.market = p_market
          AND ph.daily_price IS NOT NULL
          AND ph.date = CURRENT_DATE - 1
    )
    SELECT
        t.td_name,
        t.td_series,
        t.td_rarity,
        ROUND(t.td_price, 2),
        ROUND(y.yd_price, 2),
        t.td_change,
        t.td_source
    FROM today_data t
    LEFT JOIN yesterday_data y
        ON y.yd_name = t.td_name
        AND y.yd_series = t.td_series
        AND y.yd_rarity = t.td_rarity
    WHERE
        CASE
            WHEN p_direction = 'gainers' THEN t.td_change > 0
            WHEN p_direction = 'losers' THEN t.td_change < 0
            ELSE t.td_change <> 0
        END
    ORDER BY
        CASE WHEN p_direction = 'losers' THEN t.td_change END ASC,
        CASE WHEN p_direction != 'losers' THEN t.td_change END DESC
    LIMIT p_limit;

    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_trending_cards(TEXT, TEXT, INTEGER) IS
'涨跌幅 TOP：今日飙升(gainers)/今日暴跌(losers)/全部(both)';

-- =====================================================================
-- 六、市场热度指数 RPC
--    注意：波动率计算拆分为两步 CTE，避免窗口函数嵌套在聚合中
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_market_heat_index(
    p_market TEXT DEFAULT 'CN'
) RETURNS JSON AS $$
DECLARE
    v_result JSON;
    v_avg_change NUMERIC;
BEGIN
    SELECT AVG(change_percent) INTO v_avg_change
    FROM public.price_history
    WHERE market = p_market AND daily_price IS NOT NULL
      AND date = CURRENT_DATE;

    SELECT json_build_object(
        'date', CURRENT_DATE,
        'total_tracked', (
            SELECT COUNT(DISTINCT card_name || series || rarity)
            FROM public.price_history
            WHERE market = p_market AND daily_price IS NOT NULL AND date = CURRENT_DATE
        ),
        'gainers', (
            SELECT COUNT(*) FROM public.price_history
            WHERE market = p_market AND daily_price IS NOT NULL
              AND date = CURRENT_DATE AND change_percent > 0
        ),
        'losers', (
            SELECT COUNT(*) FROM public.price_history
            WHERE market = p_market AND daily_price IS NOT NULL
              AND date = CURRENT_DATE AND change_percent < 0
        ),
        'unchanged', (
            SELECT COUNT(*) FROM public.price_history
            WHERE market = p_market AND daily_price IS NOT NULL
              AND date = CURRENT_DATE AND change_percent = 0
        ),
        'avg_change_percent', COALESCE(ROUND(v_avg_change, 2), 0),
        'avg_volatility_7d', (
            WITH returns AS (
                SELECT
                    card_name, series, rarity,
                    daily_price / LAG(daily_price) OVER (
                        PARTITION BY card_name, series, rarity ORDER BY date
                    ) - 1 AS daily_return
                FROM public.price_history
                WHERE market = p_market AND daily_price IS NOT NULL
                  AND date >= CURRENT_DATE - 7
            ),
            vol AS (
                SELECT card_name, series, rarity, STDDEV(daily_return) AS v
                FROM returns
                WHERE daily_return IS NOT NULL
                GROUP BY card_name, series, rarity
            )
            SELECT COALESCE(ROUND(AVG(v) * 100, 2), 0) FROM vol WHERE v IS NOT NULL
        ),
        'market_sentiment', (
            CASE
                WHEN v_avg_change > 2 THEN 'greedy'
                WHEN v_avg_change > 0 THEN 'neutral_bullish'
                WHEN v_avg_change > -2 THEN 'neutral_bearish'
                ELSE 'fearful'
            END
        ),
        'top_gainer', (
            SELECT json_build_object(
                'card_name', card_name,
                'change_percent', change_percent,
                'price', daily_price
            )
            FROM public.price_history
            WHERE market = p_market AND daily_price IS NOT NULL
              AND date = CURRENT_DATE
            ORDER BY change_percent DESC LIMIT 1
        ),
        'top_loser', (
            SELECT json_build_object(
                'card_name', card_name,
                'change_percent', change_percent,
                'price', daily_price
            )
            FROM public.price_history
            WHERE market = p_market AND daily_price IS NOT NULL
              AND date = CURRENT_DATE
            ORDER BY change_percent ASC LIMIT 1
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_market_heat_index(TEXT) IS
'市场热度指数：涨跌家数、平均波动率、市场情绪（greedy/neutral/fearful）';

-- =====================================================================
-- 七、完整性验证
-- =====================================================================
DO $$
BEGIN
    RAISE NOTICE '[0022] price_history 市场趋势系统迁移完成';
    RAISE NOTICE '  升级表: price_history (+ daily_price, change_percent, series, rarity, price_source)';
    RAISE NOTICE '  新增索引: idx_price_history_daily_unique (部分唯一)';
    RAISE NOTICE '  新增函数:';
    RAISE NOTICE '    take_daily_price_snapshot()       — 每日快照';
    RAISE NOTICE '    get_card_price_trend()            — 单卡趋势(7d/30d均价+波动率)';
    RAISE NOTICE '    get_market_volatility_ranking()   — 波动率排行';
    RAISE NOTICE '    get_trending_cards()              — 涨跌幅TOP';
    RAISE NOTICE '    get_market_heat_index()           — 市场热度指数';
    RAISE NOTICE '';
    RAISE NOTICE '  ⚠️ 执行后需运行:';
    RAISE NOTICE '    SELECT * FROM take_daily_price_snapshot(''CN'');';
END $$;
