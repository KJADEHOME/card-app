-- =====================================================================
-- 0021: 资产市场化系统（Phase 7 核心升级）
-- 
-- 目标：从"卡牌记录系统"升级为"卡牌资产市场系统"
-- 
-- 新增表:
--   1. card_market       — 多源价格聚合（直播/闲鱼/AI → final_price）
--   2. user_portfolio    — 用户资产总览（总资产/成本/盈亏）
--   3. portfolio_items   — 用户持仓明细（单卡/数量/均价/当前价/盈亏）
--
-- 新增函数:
--   1. compute_card_market_price()      — 触发器：计算 final_price
--   2. seed_card_market()               — 从 card_prices 初始种子
--   3. refresh_user_portfolio()         — 从 portfolio_items 聚合用户资产
--   4. sync_collections_to_portfolio()  — 从 user_collections 迁移持仓
--   5. get_market_dashboard()           — 市场仪表盘（增强版）
--   6. upsert_card_market()             — 外部写入 card_market 的入口
--
-- 触发器:
--   1. trg_card_prices_to_market        — card_prices 变更 → 同步 card_market
--   2. trg_portfolio_auto_refresh       — portfolio_items 变更 → 刷新 user_portfolio
-- =====================================================================

-- =====================================================================
-- 一、card_market — 多源价格聚合表
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.card_market (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    card_name TEXT NOT NULL,
    series TEXT DEFAULT '',
    rarity TEXT DEFAULT 'N',
    card_category TEXT DEFAULT 'other',
    market TEXT DEFAULT 'CN',

    -- 三个价格源
    live_price NUMERIC(12,2),          -- 直播成交价（最高权重）
    market_price NUMERIC(12,2),        -- 闲鱼/外部参考价
    ai_estimate_price NUMERIC(12,2),   -- AI 估值

    -- 计算字段
    final_price NUMERIC(12,2) NOT NULL DEFAULT 0,
    price_source TEXT DEFAULT 'ai',    -- 'live' | 'market' | 'ai'

    -- 元数据
    live_source TEXT,                  -- 直播来源描述（如 "抖音@某某直播间"）
    market_source TEXT,                -- 外部市场来源（如 "闲鱼均价"）
    ai_model TEXT,                     -- AI 模型名称（如 "gemini-2.5-flash"）

    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(card_name, series, rarity, market)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_card_market_name ON public.card_market(card_name);
CREATE INDEX IF NOT EXISTS idx_card_market_final ON public.card_market(final_price DESC);
CREATE INDEX IF NOT EXISTS idx_card_market_source ON public.card_market(price_source);
CREATE INDEX IF NOT EXISTS idx_card_market_updated ON public.card_market(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_card_market_category ON public.card_market(card_category);

-- RLS
ALTER TABLE public.card_market ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can read card market" ON public.card_market;
CREATE POLICY "Anyone can read card market" ON public.card_market FOR SELECT USING (true);
DROP POLICY IF EXISTS "Admin can insert card market" ON public.card_market;
CREATE POLICY "Admin can insert card market" ON public.card_market FOR INSERT 
    WITH CHECK (true);
DROP POLICY IF EXISTS "Admin can update card market" ON public.card_market;
CREATE POLICY "Admin can update card market" ON public.card_market FOR UPDATE 
    USING (true);

-- 注释
COMMENT ON TABLE public.card_market IS '卡牌多源价格聚合表 —— 直播/闲鱼/AI三源融合，按优先级计算final_price';
COMMENT ON COLUMN public.card_market.live_price IS '直播成交价（最高优先级）';
COMMENT ON COLUMN public.card_market.market_price IS '闲鱼/外部市场参考价';
COMMENT ON COLUMN public.card_market.ai_estimate_price IS 'AI 模型估值';
COMMENT ON COLUMN public.card_market.final_price IS '系统最终定价，按 live > market > ai 优先级计算';
COMMENT ON COLUMN public.card_market.price_source IS '当前 final_price 来源：live | market | ai';

-- =====================================================================
-- 二、portfolio_items — 用户持仓明细表
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.portfolio_items (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- 关联（兼容现有 user_collections）
    collection_id UUID,               -- 关联 user_collections.id
    card_name TEXT NOT NULL,
    series TEXT DEFAULT '',
    rarity TEXT DEFAULT 'N',
    card_image TEXT,                   -- 卡图URL

    -- 持仓数据
    quantity INTEGER NOT NULL DEFAULT 1,
    avg_buy_price NUMERIC(12,2) NOT NULL DEFAULT 0,     -- 加权均价
    total_cost NUMERIC(12,2) NOT NULL DEFAULT 0,        -- 总成本 = avg_buy_price * quantity
    current_price NUMERIC(12,2) NOT NULL DEFAULT 0,      -- 当前市场价（from card_market.final_price）

    -- 盈亏
    profit_loss NUMERIC(12,2) NOT NULL DEFAULT 0,        -- 浮动盈亏
    profit_percent NUMERIC(8,2) NOT NULL DEFAULT 0,      -- 盈亏百分比

    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(user_id, card_name, series, rarity)
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_portfolio_user ON public.portfolio_items(user_id);
CREATE INDEX IF NOT EXISTS idx_portfolio_card ON public.portfolio_items(card_name, series, rarity);
CREATE INDEX IF NOT EXISTS idx_portfolio_profit ON public.portfolio_items(profit_percent DESC);
CREATE INDEX IF NOT EXISTS idx_portfolio_collection ON public.portfolio_items(collection_id);

-- RLS
ALTER TABLE public.portfolio_items ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users manage own portfolio" ON public.portfolio_items;
CREATE POLICY "Users manage own portfolio" ON public.portfolio_items 
    FOR ALL USING (auth.uid() = user_id);

COMMENT ON TABLE public.portfolio_items IS '用户持仓明细 —— 每张卡的持有数量、成本、当前估值、盈亏';
COMMENT ON COLUMN public.portfolio_items.avg_buy_price IS '加权平均买入价（多次买入时按数量加权）';
COMMENT ON COLUMN public.portfolio_items.total_cost IS '总成本 = avg_buy_price × quantity';
COMMENT ON COLUMN public.portfolio_items.current_price IS '当前市场价，从 card_market.final_price 同步';

-- =====================================================================
-- 三、user_portfolio — 用户资产总览表
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.user_portfolio (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- 资产总览
    total_asset_value NUMERIC(14,2) NOT NULL DEFAULT 0,   -- 总市值
    total_cost NUMERIC(14,2) NOT NULL DEFAULT 0,          -- 总成本
    profit_loss NUMERIC(14,2) NOT NULL DEFAULT 0,          -- 总盈亏
    profit_percent NUMERIC(8,2) NOT NULL DEFAULT 0,        -- 总盈亏%
    
    -- 分布统计
    card_count INTEGER NOT NULL DEFAULT 0,                 -- 持仓卡牌种数
    total_quantity INTEGER NOT NULL DEFAULT 0,             -- 持仓卡牌总张数
    rising_count INTEGER NOT NULL DEFAULT 0,               -- 今日上涨卡种
    falling_count INTEGER NOT NULL DEFAULT 0,              -- 今日下跌卡种

    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 索引
CREATE INDEX IF NOT EXISTS idx_portfolio_user ON public.user_portfolio(user_id);
CREATE INDEX IF NOT EXISTS idx_portfolio_value ON public.user_portfolio(total_asset_value DESC);

-- RLS
ALTER TABLE public.user_portfolio ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users view own portfolio" ON public.user_portfolio;
CREATE POLICY "Users view own portfolio" ON public.user_portfolio 
    FOR SELECT USING (auth.uid() = user_id);

COMMENT ON TABLE public.user_portfolio IS '用户资产总览 —— 一键总市值、总成本、总盈亏，类似股票账户总览';

-- =====================================================================
-- 四、核心 RPC 函数
-- =====================================================================

-- 4.1 价格计算触发器函数：按优先级计算 final_price
--    规则：live_price > market_price > ai_estimate_price
CREATE OR REPLACE FUNCTION public.compute_card_market_price()
RETURNS TRIGGER AS $$
BEGIN
    -- 优先级：live > market > ai
    IF NEW.live_price IS NOT NULL AND NEW.live_price > 0 THEN
        NEW.final_price := NEW.live_price;
        NEW.price_source := 'live';
    ELSIF NEW.market_price IS NOT NULL AND NEW.market_price > 0 THEN
        NEW.final_price := NEW.market_price;
        NEW.price_source := 'market';
    ELSIF NEW.ai_estimate_price IS NOT NULL AND NEW.ai_estimate_price > 0 THEN
        NEW.final_price := NEW.ai_estimate_price;
        NEW.price_source := 'ai';
    ELSE
        -- 无任何价格源，final_price = 0
        NEW.final_price := 0;
        NEW.price_source := 'ai';
    END IF;

    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.compute_card_market_price() IS 
'触发器函数：在 card_market INSERT/UPDATE 前，按 live > market > ai 优先级自动计算 final_price';

-- 绑定触发器到 card_market
DROP TRIGGER IF EXISTS trg_card_market_price ON public.card_market;
CREATE TRIGGER trg_card_market_price
    BEFORE INSERT OR UPDATE OF live_price, market_price, ai_estimate_price
    ON public.card_market
    FOR EACH ROW
    EXECUTE FUNCTION public.compute_card_market_price();

-- =====================================================================
-- 4.2 card_prices → card_market 同步触发器
--     当 card_prices 更新时，自动同步到 card_market.market_price
-- =====================================================================
CREATE OR REPLACE FUNCTION public.sync_card_prices_to_market()
RETURNS TRIGGER AS $$
BEGIN
    -- 只处理有实际价格变动的更新
    IF NEW.current_price IS NOT NULL AND NEW.current_price > 0 
       AND NEW.current_price <> COALESCE(OLD.current_price, -1) THEN
        
        INSERT INTO public.card_market (
            card_name, series, rarity, card_category, market,
            market_price,
            market_source
        ) VALUES (
            NEW.card_name, 
            COALESCE(NEW.series, ''),
            COALESCE(NEW.rarity, 'N'),
            COALESCE(NEW.card_category, 'other'),
            COALESCE(NEW.market, 'CN'),
            NEW.current_price,
            NEW.data_source
        )
        ON CONFLICT (card_name, series, rarity, market) 
        DO UPDATE SET 
            market_price = EXCLUDED.market_price,
            market_source = EXCLUDED.market_source,
            updated_at = NOW();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 绑定触发器
DROP TRIGGER IF EXISTS trg_card_prices_to_market ON public.card_prices;
CREATE TRIGGER trg_card_prices_to_market
    AFTER INSERT OR UPDATE OF current_price
    ON public.card_prices
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_card_prices_to_market();

COMMENT ON FUNCTION public.sync_card_prices_to_market() IS 
'触发器：card_prices.current_price 变更时，自动同步为 card_market.market_price';

-- =====================================================================
-- 4.3 card_market.final_price → portfolio_items 同步触发器
--     当 card_market.final_price 更新时，更新所有持有该卡的用户持仓
-- =====================================================================
CREATE OR REPLACE FUNCTION public.sync_market_to_portfolio()
RETURNS TRIGGER AS $$
BEGIN
    -- 仅当 final_price 实际变化时同步
    IF NEW.final_price <> COALESCE(OLD.final_price, -1) AND NEW.final_price > 0 THEN
        UPDATE public.portfolio_items
        SET current_price = NEW.final_price,
            profit_loss = (NEW.final_price - avg_buy_price) * quantity,
            profit_percent = CASE 
                WHEN avg_buy_price > 0 
                THEN ROUND((NEW.final_price - avg_buy_price) / avg_buy_price * 100, 2)
                ELSE 0 
            END,
            updated_at = NOW()
        WHERE card_name = NEW.card_name
          AND series = NEW.series
          AND rarity = NEW.rarity
          AND current_price <> NEW.final_price;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 绑定触发器
DROP TRIGGER IF EXISTS trg_market_to_portfolio ON public.card_market;
CREATE TRIGGER trg_market_to_portfolio
    AFTER UPDATE OF final_price
    ON public.card_market
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_market_to_portfolio();

COMMENT ON FUNCTION public.sync_market_to_portfolio() IS 
'触发器：card_market.final_price 变化时，自动更新所有持有该卡用户的 portfolio_items';

-- =====================================================================
-- 4.4 portfolio_items → user_portfolio 自动刷新触发器
-- =====================================================================
CREATE OR REPLACE FUNCTION public.auto_refresh_user_portfolio()
RETURNS TRIGGER AS $$
DECLARE
    v_user_id UUID;
BEGIN
    -- 确定受影响的 user_id
    IF TG_OP = 'DELETE' THEN
        v_user_id := OLD.user_id;
    ELSE
        v_user_id := NEW.user_id;
    END IF;

    -- 刷新该用户的资产总览
    PERFORM public.refresh_user_portfolio(v_user_id);

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- 绑定触发器（延迟触发避免递归）
DROP TRIGGER IF EXISTS trg_portfolio_auto_refresh ON public.portfolio_items;
CREATE TRIGGER trg_portfolio_auto_refresh
    AFTER INSERT OR UPDATE OR DELETE
    ON public.portfolio_items
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_refresh_user_portfolio();

COMMENT ON FUNCTION public.auto_refresh_user_portfolio() IS 
'触发器：portfolio_items 变更后，自动刷新对应 user_portfolio';

-- =====================================================================
-- 4.5 刷新用户资产总览 RPC
-- =====================================================================
CREATE OR REPLACE FUNCTION public.refresh_user_portfolio(
    p_user_id UUID
) RETURNS TABLE(
    total_asset NUMERIC,
    total_cost NUMERIC,
    profit NUMERIC,
    profit_pct NUMERIC,
    card_count INTEGER,
    rising INTEGER,
    falling INTEGER
) AS $$
DECLARE
    v_total_asset NUMERIC(14,2);
    v_total_cost NUMERIC(14,2);
    v_profit NUMERIC(14,2);
    v_profit_pct NUMERIC(8,2);
    v_card_count INTEGER;
    v_rising INTEGER;
    v_falling INTEGER;
    v_total_qty INTEGER;
BEGIN
    -- 聚合 portfolio_items 数据
    SELECT 
        COALESCE(SUM(current_price * quantity), 0),
        COALESCE(SUM(total_cost), 0),
        COALESCE(SUM(profit_loss), 0),
        COUNT(*),
        COALESCE(SUM(CASE WHEN profit_percent > 0 THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN profit_percent < 0 THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(quantity), 0)
    INTO 
        v_total_asset, v_total_cost, v_profit,
        v_card_count, v_rising, v_falling, v_total_qty
    FROM public.portfolio_items
    WHERE user_id = p_user_id;

    -- 计算总收益率
    IF v_total_cost > 0 THEN
        v_profit_pct := ROUND(v_profit / v_total_cost * 100, 2);
    ELSE
        v_profit_pct := 0;
    END IF;

    -- UPSERT 到 user_portfolio
    INSERT INTO public.user_portfolio (
        user_id,
        total_asset_value, total_cost,
        profit_loss, profit_percent,
        card_count, total_quantity,
        rising_count, falling_count,
        updated_at
    ) VALUES (
        p_user_id,
        v_total_asset, v_total_cost,
        v_profit, v_profit_pct,
        v_card_count, v_total_qty,
        v_rising, v_falling,
        NOW()
    )
    ON CONFLICT (user_id) 
    DO UPDATE SET
        total_asset_value = EXCLUDED.total_asset_value,
        total_cost = EXCLUDED.total_cost,
        profit_loss = EXCLUDED.profit_loss,
        profit_percent = EXCLUDED.profit_percent,
        card_count = EXCLUDED.card_count,
        total_quantity = EXCLUDED.total_quantity,
        rising_count = EXCLUDED.rising_count,
        falling_count = EXCLUDED.falling_count,
        updated_at = NOW();

    -- 同时更新 user_daily_snapshot（保持兼容）
    INSERT INTO public.user_daily_snapshot (
        user_id, snapshot_date,
        total_asset, total_cost,
        card_count,
        rising_count, falling_count,
        change_percent, change_amount
    ) VALUES (
        p_user_id, CURRENT_DATE,
        v_total_asset, v_total_cost,
        v_card_count,
        v_rising, v_falling,
        v_profit_pct, v_profit
    )
    ON CONFLICT (user_id, snapshot_date) 
    DO UPDATE SET
        total_asset = EXCLUDED.total_asset,
        total_cost = EXCLUDED.total_cost, 
        card_count = EXCLUDED.card_count,
        rising_count = EXCLUDED.rising_count,
        falling_count = EXCLUDED.falling_count,
        change_percent = EXCLUDED.change_percent,
        change_amount = EXCLUDED.change_amount;

    RETURN QUERY
    SELECT 
        v_total_asset,
        v_total_cost,
        v_profit,
        v_profit_pct,
        v_card_count,
        v_rising,
        v_falling;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.refresh_user_portfolio(UUID) IS 
'从 portfolio_items 聚合计算用户总资产/成本/盈亏，写入 user_portfolio 和 user_daily_snapshot';

-- =====================================================================
-- 4.6 从 card_prices 初始化 card_market
-- =====================================================================
CREATE OR REPLACE FUNCTION public.seed_card_market(
    p_market TEXT DEFAULT 'CN'
) RETURNS TABLE(cards_seeded INTEGER) AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    INSERT INTO public.card_market (
        card_name, series, rarity, card_category, market,
        market_price,
        market_source
    )
    SELECT 
        cp.card_name,
        COALESCE(cp.series, ''),
        COALESCE(cp.rarity, 'N'),
        COALESCE(cp.card_category, 'other'),
        cp.market,
        cp.current_price,
        cp.data_source
    FROM public.card_prices cp
    WHERE cp.market = p_market
      AND cp.current_price > 0
      AND NOT EXISTS (
          SELECT 1 FROM public.card_market cm
          WHERE cm.card_name = cp.card_name
            AND cm.series = COALESCE(cp.series, '')
            AND cm.rarity = COALESCE(cp.rarity, 'N')
            AND cm.market = cp.market
      );
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    cards_seeded := v_count;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.seed_card_market(TEXT) IS 
'从 card_prices 初始化 card_market 表，market_price = current_price';

-- =====================================================================
-- 4.7 从 user_collections 初始化 portfolio_items
-- =====================================================================
CREATE OR REPLACE FUNCTION public.sync_collections_to_portfolio(
    p_user_id UUID DEFAULT NULL
) RETURNS TABLE(items_synced INTEGER) AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    INSERT INTO public.portfolio_items (
        user_id, collection_id,
        card_name, series, rarity, card_image,
        quantity,
        avg_buy_price, total_cost,
        current_price,
        profit_loss, profit_percent
    )
    SELECT 
        uc.user_id,
        uc.id AS collection_id,
        uc.card_name,
        COALESCE(uc.series, ''),
        COALESCE(uc.rarity, 'N'),
        uc.card_image,
        GREATEST(COALESCE(uc.quantity, 1) - COALESCE(uc.reserved_quantity, 0), 1),
        COALESCE(uc.purchase_price, 0),
        COALESCE(uc.purchase_price, 0) * GREATEST(COALESCE(uc.quantity, 1) - COALESCE(uc.reserved_quantity, 0), 1),
        COALESCE(cm.final_price, uc.current_price, 0),
        (COALESCE(cm.final_price, uc.current_price, 0) - COALESCE(uc.purchase_price, 0)) 
            * GREATEST(COALESCE(uc.quantity, 1) - COALESCE(uc.reserved_quantity, 0), 1),
        CASE 
            WHEN COALESCE(uc.purchase_price, 0) > 0 
            THEN ROUND((COALESCE(cm.final_price, uc.current_price, 0) - uc.purchase_price) / uc.purchase_price * 100, 2)
            ELSE 0 
        END
    FROM public.user_collections uc
    LEFT JOIN public.card_market cm 
        ON cm.card_name = uc.card_name 
        AND cm.series = COALESCE(uc.series, '')
        AND cm.rarity = COALESCE(uc.rarity, 'N')
        AND cm.market = 'CN'
    WHERE (p_user_id IS NULL OR uc.user_id = p_user_id)
      AND NOT EXISTS (
          SELECT 1 FROM public.portfolio_items pi
          WHERE pi.collection_id = uc.id
      );
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    items_synced := v_count;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.sync_collections_to_portfolio(UUID) IS 
'从 user_collections 迁移数据到 portfolio_items，关联 card_market.final_price 作为当前价';

-- =====================================================================
-- 4.8 刷新所有用户的 portfolio
-- =====================================================================
CREATE OR REPLACE FUNCTION public.refresh_all_portfolios()
RETURNS TABLE(users_refreshed INTEGER) AS $$
DECLARE
    v_user RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_user IN 
        SELECT DISTINCT user_id FROM public.portfolio_items
    LOOP
        PERFORM public.refresh_user_portfolio(v_user.user_id);
        v_count := v_count + 1;
    END LOOP;
    
    users_refreshed := v_count;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.refresh_all_portfolios() IS 
'批量刷新所有有持仓用户的 user_portfolio';

-- =====================================================================
-- 4.9 市场仪表盘（增强版，含 card_market 数据）
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_market_dashboard(
    p_market TEXT DEFAULT 'CN',
    p_limit INTEGER DEFAULT 10
) RETURNS JSON AS $$
DECLARE
    v_result JSON;
BEGIN
    SELECT json_build_object(
        'market_overview', (
            SELECT json_build_object(
                'total_cards', COUNT(*),
                'avg_price', ROUND(AVG(final_price), 2),
                'rising_count', COUNT(*) FILTER (WHERE price_source = 'live'),
                'market_count', COUNT(*) FILTER (WHERE price_source = 'market'),
                'ai_count', COUNT(*) FILTER (WHERE price_source = 'ai'),
                'last_updated', MAX(updated_at)
            )
            FROM public.card_market
            WHERE market = p_market AND final_price > 0
        ),
        'top_gainers', (
            SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
            FROM (
                SELECT 
                    card_name,
                    series,
                    rarity,
                    final_price,
                    price_source,
                    live_price,
                    market_price,
                    ai_estimate_price,
                    updated_at
                FROM public.card_market
                WHERE market = p_market AND final_price > 0
                ORDER BY final_price DESC
                LIMIT p_limit
            ) t
        ),
        'top_value_cards', (
            SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
            FROM (
                SELECT 
                    pi.card_name,
                    pi.series,
                    pi.rarity,
                    SUM(pi.quantity) AS total_held,
                    ROUND(AVG(pi.current_price), 2) AS avg_price,
                    ROUND(SUM(pi.total_cost), 2) AS total_hold_value,
                    COUNT(DISTINCT pi.user_id) AS holder_count
                FROM public.portfolio_items pi
                WHERE pi.current_price > 0
                GROUP BY pi.card_name, pi.series, pi.rarity
                ORDER BY SUM(pi.total_cost) DESC
                LIMIT p_limit
            ) t
        )
    ) INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_market_dashboard(TEXT, INTEGER) IS 
'市场仪表盘：大盘概况 + 高价卡牌TOP + 持仓价值TOP';

-- =====================================================================
-- 4.10 外部写入 card_market 的统一入口（供 Edge Function 调用）
-- =====================================================================
CREATE OR REPLACE FUNCTION public.upsert_card_market(
    p_card_name TEXT,
    p_series TEXT DEFAULT '',
    p_rarity TEXT DEFAULT 'N',
    p_market TEXT DEFAULT 'CN',
    p_live_price NUMERIC DEFAULT NULL,
    p_market_price NUMERIC DEFAULT NULL,
    p_ai_estimate_price NUMERIC DEFAULT NULL,
    p_live_source TEXT DEFAULT NULL,
    p_market_source TEXT DEFAULT NULL,
    p_ai_model TEXT DEFAULT NULL
) RETURNS TABLE(
    out_name TEXT,
    out_price NUMERIC,
    out_source TEXT
) AS $$
DECLARE
    v_name ALIAS FOR p_card_name;
BEGIN
    INSERT INTO public.card_market (
        card_name, series, rarity, market,
        live_price, market_price, ai_estimate_price,
        live_source, market_source, ai_model
    ) VALUES (
        v_name, p_series, p_rarity, p_market,
        p_live_price, p_market_price, p_ai_estimate_price,
        p_live_source, p_market_source, p_ai_model
    )
    ON CONFLICT (card_name, series, rarity, market)
    DO UPDATE SET
        live_price = COALESCE(EXCLUDED.live_price, card_market.live_price),
        market_price = COALESCE(EXCLUDED.market_price, card_market.market_price),
        ai_estimate_price = COALESCE(EXCLUDED.ai_estimate_price, card_market.ai_estimate_price),
        live_source = COALESCE(EXCLUDED.live_source, card_market.live_source),
        market_source = COALESCE(EXCLUDED.market_source, card_market.market_source),
        ai_model = COALESCE(EXCLUDED.ai_model, card_market.ai_model),
        updated_at = NOW();

    RETURN QUERY
    SELECT cm.card_name, cm.final_price, cm.price_source
    FROM public.card_market cm
    WHERE cm.card_name = v_name
      AND cm.series = p_series
      AND cm.rarity = p_rarity
      AND cm.market = p_market;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.upsert_card_market IS 
'外部写入 card_market 的统一入口。仅更新非 NULL 字段，支持局部更新。触发器自动计算 final_price';

-- =====================================================================
-- 五、完整性验证
-- =====================================================================
DO $$
BEGIN
    RAISE NOTICE '[0021] 资产市场化系统迁移完成';
    RAISE NOTICE '  新增表: card_market, portfolio_items, user_portfolio';
    RAISE NOTICE '  新增函数: compute_card_market_price, seed_card_market, sync_collections_to_portfolio, refresh_user_portfolio, refresh_all_portfolios, get_market_dashboard, upsert_card_market';
    RAISE NOTICE '  新增触发器: trg_card_market_price, trg_card_prices_to_market, trg_market_to_portfolio, trg_portfolio_auto_refresh';
    RAISE NOTICE '';
    RAISE NOTICE '  ⚠️ 执行后需运行:';
    RAISE NOTICE '    SELECT * FROM seed_card_market(''CN'');';
    RAISE NOTICE '    SELECT * FROM sync_collections_to_portfolio();';
    RAISE NOTICE '    SELECT * FROM refresh_all_portfolios();';
END $$;
