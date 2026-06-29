-- ============================================================
-- 0011: 市场价格系统 & 资产估值升级
-- CardRealm MVP第二阶段 —— 卡牌资产 + 实时估值 + 价格变化
-- ============================================================

-- 1. 卡牌价格核心表（card_prices）
-- 每张卡在每个市场(CN/US)的价格记录
CREATE TABLE IF NOT EXISTS public.card_prices (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    card_name TEXT NOT NULL,
    series TEXT,
    rarity TEXT DEFAULT 'N',
    card_category TEXT DEFAULT 'other',
    current_price NUMERIC(12,2) NOT NULL DEFAULT 0,
    previous_price NUMERIC(12,2),
    change_percent NUMERIC(6,2) DEFAULT 0,
    change_amount NUMERIC(12,2) DEFAULT 0,
    market TEXT DEFAULT 'CN',
    currency TEXT DEFAULT 'CNY',
    data_source TEXT DEFAULT 'simulated',
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(card_name, series, rarity, market)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_card_prices_name ON public.card_prices(card_name);
CREATE INDEX IF NOT EXISTS idx_card_prices_change ON public.card_prices(change_percent DESC);
CREATE INDEX IF NOT EXISTS idx_card_prices_category ON public.card_prices(card_category);
CREATE INDEX IF NOT EXISTS idx_card_prices_updated ON public.card_prices(updated_at DESC);

-- RLS
ALTER TABLE public.card_prices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read card prices" ON public.card_prices FOR SELECT USING (true);

COMMENT ON TABLE public.card_prices IS '卡牌市场价格表 —— 驱动所有涨跌榜、资产估值、趋势图';
COMMENT ON COLUMN public.card_prices.change_percent IS '涨跌幅%（正=涨，负=跌）';
COMMENT ON COLUMN public.card_prices.data_source IS 'simulated | tcgdex | manual';

-- 2. 增强 price_history —— 添加 market_price 列
ALTER TABLE public.price_history ADD COLUMN IF NOT EXISTS market_price NUMERIC(12,2);

-- 3. 增强 user_collections —— 添加价格变化字段和自动更新标记
ALTER TABLE public.user_collections ADD COLUMN IF NOT EXISTS change_percent NUMERIC(6,2) DEFAULT 0;
ALTER TABLE public.user_collections ADD COLUMN IF NOT EXISTS price_updated_at TIMESTAMPTZ;

COMMENT ON COLUMN public.user_collections.change_percent IS '该卡牌今日涨跌幅（从card_prices同步）';
COMMENT ON COLUMN public.user_collections.price_updated_at IS '价格上次同步时间';

-- 4. 增强 daily_market_stats —— 补全字段
ALTER TABLE public.daily_market_stats ADD COLUMN IF NOT EXISTS market TEXT DEFAULT 'CN';
CREATE INDEX IF NOT EXISTS idx_daily_stats_market ON public.daily_market_stats(market, date);

-- ============================================================
-- RPC 函数：价格模拟波动
-- 对所有 card_prices 中的卡牌应用 ±1%~±8% 随机波动
-- ============================================================
CREATE OR REPLACE FUNCTION simulate_market_fluctuation(
    p_market TEXT DEFAULT 'CN',
    p_max_change_pct NUMERIC DEFAULT 8.0,
    p_min_change_pct NUMERIC DEFAULT 1.0
) RETURNS TABLE(
    cards_updated INTEGER,
    avg_change_pct NUMERIC,
    rising_count INTEGER,
    falling_count INTEGER
) AS $$
DECLARE
    v_card RECORD;
    v_new_price NUMERIC(12,2);
    v_change_pct NUMERIC(6,2);
    v_change_amt NUMERIC(12,2);
    v_rising INTEGER := 0;
    v_falling INTEGER := 0;
    v_count INTEGER := 0;
    v_total_change NUMERIC := 0;
BEGIN
    -- 遍历所有有价格的卡牌
    FOR v_card IN
        SELECT id, card_name, series, rarity, current_price, market
        FROM public.card_prices
        WHERE market = p_market AND current_price > 0
    LOOP
        -- 随机波动幅度（±1%~±8%），略微偏向上涨（55%概率涨）
        v_change_pct := (random() * (p_max_change_pct - p_min_change_pct) + p_min_change_pct);
        IF random() > 0.55 THEN
            v_change_pct := -v_change_pct; -- 45%概率下跌
        END IF;
        
        v_change_amt := ROUND(v_card.current_price * v_change_pct / 100.0, 2);
        v_new_price := GREATEST(v_card.current_price + v_change_amt, 0.01);

        -- 更新 card_prices
        UPDATE public.card_prices
        SET previous_price = current_price,
            current_price = v_new_price,
            change_percent = ROUND(v_change_pct, 2),
            change_amount = v_change_amt,
            updated_at = NOW()
        WHERE id = v_card.id;

        -- 写入 price_history
        INSERT INTO public.price_history (
            card_id, card_name, card_category, 
            price_mid, market_price, currency, market, date
        ) VALUES (
            '', v_card.card_name, COALESCE(
                (SELECT card_category FROM public.card_prices WHERE id = v_card.id), 'other'
            ),
            v_new_price, v_new_price, 
            CASE WHEN p_market = 'CN' THEN 'CNY' ELSE 'USD' END,
            p_market, CURRENT_DATE
        ) ON CONFLICT (card_id, market, date) DO UPDATE
        SET price_mid = EXCLUDED.price_mid,
            market_price = EXCLUDED.market_price;

        -- 统计数据
        IF v_change_pct > 0 THEN v_rising := v_rising + 1; ELSE v_falling := v_falling + 1; END IF;
        v_count := v_count + 1;
        v_total_change := v_total_change + ABS(v_change_pct);
    END LOOP;

    -- 写入 daily_market_stats
    IF v_count > 0 THEN
        INSERT INTO public.daily_market_stats (date, category, rising_count, falling_count, avg_change_pct, total_cards, market)
        VALUES (CURRENT_DATE, 'all', v_rising, v_falling, ROUND(v_total_change / v_count, 2), v_count, p_market)
        ON CONFLICT (date) DO UPDATE
        SET rising_count = EXCLUDED.rising_count,
            falling_count = EXCLUDED.falling_count,
            avg_change_pct = EXCLUDED.avg_change_pct,
            total_cards = EXCLUDED.total_cards;
    END IF;

    avg_change_pct := CASE WHEN v_count > 0 THEN ROUND(v_total_change / v_count, 2) ELSE 0 END;
    rising_count := v_rising;
    falling_count := v_falling;
    cards_updated := v_count;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 函数：同步 user_collections 价格（从 card_prices 拉取最新价）
-- ============================================================
CREATE OR REPLACE FUNCTION sync_user_collections_prices(p_user_id UUID DEFAULT NULL)
RETURNS TABLE(cards_synced INTEGER) AS $$
DECLARE
    v_card RECORD;
    v_count INTEGER := 0;
BEGIN
    -- 遍历需要更新的 user_collections 记录
    FOR v_card IN
        SELECT uc.id, uc.card_name, uc.series, uc.rarity,
               cp.current_price, cp.change_percent
        FROM public.user_collections uc
        LEFT JOIN public.card_prices cp 
            ON cp.card_name = uc.card_name 
            AND COALESCE(cp.series, '') = COALESCE(uc.series, '')
            AND COALESCE(cp.rarity, 'N') = COALESCE(uc.rarity, 'N')
            AND cp.market = 'CN'
        WHERE (p_user_id IS NULL OR uc.user_id = p_user_id)
          AND cp.current_price IS NOT NULL
          AND cp.current_price > 0
          AND (uc.price_updated_at IS NULL OR uc.price_updated_at < NOW() - INTERVAL '6 hours')
    LOOP
        UPDATE public.user_collections
        SET current_price = v_card.current_price,
            change_percent = v_card.change_percent,
            price_updated_at = NOW()
        WHERE id = v_card.id;
        v_count := v_count + 1;
    END LOOP;

    cards_synced := v_count;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 函数：初始化卡牌价格（从 price_history 导入有数据的卡牌）
-- 用于首次启动时的数据填充
-- ============================================================
CREATE OR REPLACE FUNCTION seed_card_prices_from_history(p_market TEXT DEFAULT 'CN')
RETURNS TABLE(cards_seeded INTEGER) AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    INSERT INTO public.card_prices (card_name, series, rarity, card_category, current_price, market, currency, data_source)
    SELECT DISTINCT ON (ph.card_name, COALESCE(ph.market, p_market))
        ph.card_name,
        'Pokemon' AS series,
        'N' AS rarity,
        ph.card_category,
        COALESCE(ph.market_price, ph.price_mid, 0) AS current_price,
        COALESCE(ph.market, p_market) AS market,
        CASE WHEN COALESCE(ph.market, p_market) = 'CN' THEN 'CNY' ELSE 'USD' END AS currency,
        'tcgdex' AS data_source
    FROM public.price_history ph
    WHERE COALESCE(ph.market_price, ph.price_mid, 0) > 0
      AND COALESCE(ph.market, p_market) = p_market
    ORDER BY ph.card_name, COALESCE(ph.market, p_market), ph.date DESC
    ON CONFLICT (card_name, series, rarity, market) DO UPDATE
    SET current_price = EXCLUDED.current_price,
        data_source = EXCLUDED.data_source,
        updated_at = NOW();

    GET DIAGNOSTICS v_count = ROW_COUNT;
    cards_seeded := v_count;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 函数：获取资产快照（每日自动调用）
-- ============================================================
CREATE OR REPLACE FUNCTION take_asset_snapshot()
RETURNS TABLE(snapshots_taken INTEGER) AS $$
DECLARE
    v_user RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_user IN
        SELECT DISTINCT user_id FROM public.user_collections
    LOOP
        INSERT INTO public.collection_price_snapshots (
            user_id, date,
            total_cost, total_value, total_profit, profit_pct, card_count
        )
        SELECT 
            v_user.user_id,
            CURRENT_DATE,
            COALESCE(SUM(purchase_price * quantity), 0) AS total_cost,
            COALESCE(SUM(COALESCE(current_price, purchase_price) * quantity), 0) AS total_value,
            COALESCE(SUM(COALESCE(current_price, purchase_price) * quantity), 0) - COALESCE(SUM(purchase_price * quantity), 0) AS total_profit,
            CASE 
                WHEN COALESCE(SUM(purchase_price * quantity), 0) > 0 
                THEN ROUND(((COALESCE(SUM(COALESCE(current_price, purchase_price) * quantity), 0) - COALESCE(SUM(purchase_price * quantity), 0)) / COALESCE(SUM(purchase_price * quantity), 1)) * 100, 2)
                ELSE 0
            END AS profit_pct,
            SUM(quantity) AS card_count
        FROM public.user_collections
        WHERE user_id = v_user.user_id
        ON CONFLICT (user_id, date) DO UPDATE
        SET total_cost = EXCLUDED.total_cost,
            total_value = EXCLUDED.total_value,
            total_profit = EXCLUDED.total_profit,
            profit_pct = EXCLUDED.profit_pct,
            card_count = EXCLUDED.card_count;

        v_count := v_count + 1;
    END LOOP;

    snapshots_taken := v_count;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- RPC 函数：市场概述（涨跌统计）
-- ============================================================
CREATE OR REPLACE FUNCTION get_market_overview(p_market TEXT DEFAULT 'CN')
RETURNS JSON AS $$
DECLARE
    v_rising INTEGER;
    v_falling INTEGER;
    v_total INTEGER;
    v_avg_change NUMERIC(6,2);
    v_result JSON;
BEGIN
    SELECT COUNT(*) INTO v_rising FROM public.card_prices WHERE market = p_market AND change_percent > 0;
    SELECT COUNT(*) INTO v_falling FROM public.card_prices WHERE market = p_market AND change_percent < 0;
    SELECT COUNT(*) INTO v_total FROM public.card_prices WHERE market = p_market AND current_price > 0;
    SELECT ROUND(AVG(ABS(change_percent)), 2) INTO v_avg_change FROM public.card_prices WHERE market = p_market AND change_percent != 0;

    -- 取昨日数据对比
    v_result := json_build_object(
        'rising', COALESCE(v_rising, 0),
        'falling', COALESCE(v_falling, 0),
        'total', COALESCE(v_total, 0),
        'avg_change', COALESCE(v_avg_change, 0),
        'last_updated', (SELECT MAX(updated_at) FROM public.card_prices WHERE market = p_market)
    );

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
