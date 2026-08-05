-- ================================================
-- P8: 动态权重市场定价引擎（Dynamic Weight Pricing Engine）
-- 目标：mark_price = normalize(live*w_live + market*w_market + ai*w_ai)
-- 约束：不删除 final_price，mark_price 为新增层
-- ================================================

-- ── 1. card_market 新增列 ───────────────────────────

ALTER TABLE public.card_market
  ADD COLUMN IF NOT EXISTS activity_score NUMERIC(5,4) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS w_live NUMERIC(5,4) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS w_market NUMERIC(5,4) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS w_ai NUMERIC(5,4) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS mark_price NUMERIC(12,2) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS mark_price_prev NUMERIC(12,2) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS volatility_24h NUMERIC(5,4) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS trade_count_24h INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS unique_buyers_24h INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS mark_price_updated_at TIMESTAMPTZ DEFAULT NOW();

COMMENT ON COLUMN public.card_market.activity_score IS '市场活跃度 0~1（动态权重输入）';
COMMENT ON COLUMN public.card_market.w_live IS 'live_price 动态权重';
COMMENT ON COLUMN public.card_market.w_market IS 'market_price 动态权重';
COMMENT ON COLUMN public.card_market.w_ai IS 'ai_price 动态权重';
COMMENT ON COLUMN public.card_market.mark_price IS '平滑市场价（EMA 0.3n+0.7o，防抖 ±25%）';
COMMENT ON COLUMN public.card_market.mark_price_prev IS '上一次 mark_price（用于防抖比较）';
COMMENT ON COLUMN public.card_market.volatility_24h IS '24h 波动率（0~1）';
COMMENT ON COLUMN public.card_market.trade_count_24h IS '24h 成交笔数';
COMMENT ON COLUMN public.card_market.unique_buyers_24h IS '24h 独立买家数';
COMMENT ON COLUMN public.card_market.mark_price_updated_at IS 'mark_price 最后更新时间';

-- ── 2. price_activity_stats 表（24h 活跃度数据源）───────────────────────────

CREATE TABLE IF NOT EXISTS public.price_activity_stats (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    card_name TEXT NOT NULL,
    series TEXT NOT NULL DEFAULT '',
    rarity TEXT NOT NULL DEFAULT 'N',
    market TEXT NOT NULL DEFAULT 'CN',
    window_start TIMESTAMPTZ NOT NULL,
    window_end TIMESTAMPTZ NOT NULL,
    trade_count_24h INTEGER DEFAULT 0,
    unique_buyers_24h INTEGER DEFAULT 0,
    volatility_24h NUMERIC(5,4) DEFAULT 0.00,
    price_stddev_24h NUMERIC(12,2) DEFAULT 0.00,
    computed_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(card_name, series, rarity, market, window_start)
);

CREATE INDEX IF NOT EXISTS idx_price_activity_stats_card
    ON public.price_activity_stats(card_name, series, rarity, market, window_start DESC);

COMMENT ON TABLE public.price_activity_stats IS '卡牌 24h 市场活跃度统计数据（供 activity_score 计算）';

-- ── 3. RPC: compute_activity_score ───────────────────────────

CREATE OR REPLACE FUNCTION public.compute_activity_score(
    p_trade_count INTEGER,
    p_volatility NUMERIC,
    p_unique_buyers INTEGER
) RETURNS NUMERIC(5,4) AS $$
DECLARE
    v_score NUMERIC(5,4);
    v_trade_comp NUMERIC(5,4) := 0.0;
    v_vol_comp   NUMERIC(5,4) := 0.0;
    v_buyer_comp NUMERIC(5,4) := 0.0;
BEGIN
    -- activity_score = log(1 + trade_count) * 0.5 + volatility * 0.3 + buyers * 0.2
    -- 各项归一化到 0~1 区间后再加权

    -- log(1+tc) 按 tc=100 归一化 → LEAST(raw, 1.0)
    v_trade_comp := LEAST(LN(1.0 + COALESCE(p_trade_count, 0)) / LN(101.0), 1.0) * 0.5;

    -- volatility 本身 0~1
    v_vol_comp := LEAST(COALESCE(p_volatility, 0), 1.0) * 0.3;

    -- buyers 按 max=50 归一化
    v_buyer_comp := LEAST(COALESCE(p_unique_buyers, 0) / 50.0, 1.0) * 0.2;

    v_score := v_trade_comp + v_vol_comp + v_buyer_comp;
    v_score := LEAST(GREATEST(v_score, 0.0), 1.0);
    RETURN ROUND(v_score, 4);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION public.compute_activity_score IS '计算市场活跃度 0~1（trade_count/volatility/buyers 加权）';

-- ── 4. RPC: compute_dynamic_weights ───────────────────────────

CREATE OR REPLACE FUNCTION public.compute_dynamic_weights(
    p_activity_score NUMERIC(5,4)
) RETURNS TABLE(
    out_w_live NUMERIC(5,4),
    out_w_market NUMERIC(5,4),
    out_w_ai NUMERIC(5,4),
    out_activity_level TEXT
) AS $$
DECLARE
    v_score NUMERIC(5,4);
BEGIN
    v_score := GREATEST(LEAST(p_activity_score, 1.0), 0.0);

    -- 高活跃（0.7~1.0）
    IF v_score >= 0.7 THEN
        out_w_live  := 0.7500;
        out_w_market := 0.2000;
        out_w_ai     := 0.0500;
        out_activity_level := 'high';
    -- 中活跃（0.3~0.7）
    ELSIF v_score >= 0.3 THEN
        out_w_live  := 0.5500;
        out_w_market := 0.3500;
        out_w_ai     := 0.1000;
        out_activity_level := 'medium';
    -- 低活跃（0~0.3）
    ELSE
        out_w_live  := 0.2000;
        out_w_market := 0.5000;
        out_w_ai     := 0.3000;
        out_activity_level := 'low';
    END IF;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION public.compute_dynamic_weights IS '根据 activity_score 返回动态权重 + 活跃等级';

-- ── 5. RPC: compute_mark_price（含归一化 + EMA 平滑 + 25% 防抖）───────────────────────────

CREATE OR REPLACE FUNCTION public.compute_mark_price(
    p_live_price NUMERIC,
    p_market_price NUMERIC,
    p_ai_price NUMERIC,
    p_w_live NUMERIC,
    p_w_market NUMERIC,
    p_w_ai NUMERIC,
    p_old_mark_price NUMERIC DEFAULT NULL
) RETURNS NUMERIC(12,2) AS $$
DECLARE
    v_raw NUMERIC(12,2);
    v_normalized NUMERIC(12,2);
    v_ema NUMERIC(12,2);
    v_prev NUMERIC(12,2);
    v_total_weight NUMERIC(5,4) := 0.0;
    v_weighted_sum NUMERIC(12,2) := 0.0;
    v_live NUMERIC(12,2) := COALESCE(p_live_price, 0);
    v_market NUMERIC(12,2) := COALESCE(p_market_price, 0);
    v_ai NUMERIC(12,2) := COALESCE(p_ai_price, 0);
BEGIN
    -- Step 1: 归一化权重（NULL 来源权重重新分配）
    IF v_live > 0 THEN v_total_weight := v_total_weight + p_w_live; END IF;
    IF v_market > 0 THEN v_total_weight := v_total_weight + p_w_market; END IF;
    IF v_ai > 0 THEN v_total_weight := v_total_weight + p_w_ai; END IF;

    IF v_total_weight = 0.0 THEN RETURN NULL; END IF;

    -- 归一化
    IF v_live > 0 THEN
        v_weighted_sum := v_weighted_sum + v_live * (p_w_live / v_total_weight);
    END IF;
    IF v_market > 0 THEN
        v_weighted_sum := v_weighted_sum + v_market * (p_w_market / v_total_weight);
    END IF;
    IF v_ai > 0 THEN
        v_weighted_sum := v_weighted_sum + v_ai * (p_w_ai / v_total_weight);
    END IF;

    v_raw := ROUND(v_weighted_sum, 2);

    -- Step 2: EMA 平滑（0.3 * new + 0.7 * old）
    v_prev := COALESCE(p_old_mark_price, v_raw);
    v_ema := ROUND(0.3 * v_raw + 0.7 * v_prev, 2);

    -- Step 3: 防抖（最大变化 ±25%）
    IF v_prev > 0 AND v_ema > 0 THEN
        IF v_ema > v_prev * 1.25 THEN
            v_ema := ROUND(v_prev * 1.25, 2);
        ELSIF v_ema < v_prev * 0.75 THEN
            v_ema := ROUND(v_prev * 0.75, 2);
        END IF;
    END IF;

    RETURN v_ema;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION public.compute_mark_price IS '计算 mark_price：归一化加权 + EMA(0.3,0.7) + 防抖±25%';

-- ── 6. RPC: get_mark_price_with_explanation ───────────────────────────

DROP TYPE IF EXISTS mark_price_result CASCADE;
CREATE TYPE mark_price_result AS (
    mark_price NUMERIC(12,2),
    activity_score NUMERIC(5,4),
    w_live NUMERIC(5,4),
    w_market NUMERIC(5,4),
    w_ai NUMERIC(5,4),
    activity_level TEXT,
    price_sources_status JSON,
    stability_flag TEXT
);

CREATE OR REPLACE FUNCTION public.get_mark_price_with_explanation(
    p_card_name TEXT,
    p_series TEXT DEFAULT '',
    p_rarity TEXT DEFAULT 'N',
    p_market TEXT DEFAULT 'CN'
) RETURNS mark_price_result AS $$
DECLARE
    r mark_price_result;
    v_live NUMERIC(12,2);
    v_market_price NUMERIC(12,2);
    v_ai NUMERIC(12,2);
    v_old_mark NUMERIC(12,2);
BEGIN
    SELECT
        cm.live_price, cm.market_price, cm.ai_estimate_price, cm.mark_price
    INTO v_live, v_market_price, v_ai, v_old_mark
    FROM public.card_market cm
    WHERE cm.card_name = p_card_name
      AND cm.series = p_series
      AND cm.rarity = p_rarity
      AND cm.market = p_market;

    -- 1. activity_score
    r.activity_score := public.compute_activity_score(
        COALESCE((SELECT trade_count_24h FROM public.card_market WHERE card_name=p_card_name AND series=p_series AND rarity=p_rarity AND market=p_market), 0),
        COALESCE((SELECT volatility_24h FROM public.card_market WHERE card_name=p_card_name AND series=p_series AND rarity=p_rarity AND market=p_market), 0),
        COALESCE((SELECT unique_buyers_24h FROM public.card_market WHERE card_name=p_card_name AND series=p_series AND rarity=p_rarity AND market=p_market), 0)
    );

    -- 2. weights
    SELECT out_w_live, out_w_market, out_w_ai, out_activity_level
    INTO r.w_live, r.w_market, r.w_ai, r.activity_level
    FROM public.compute_dynamic_weights(r.activity_score);

    -- 3. mark_price
    r.mark_price := public.compute_mark_price(
        v_live, v_market_price, v_ai,
        r.w_live, r.w_market, r.w_ai,
        v_old_mark
    );

    -- 4. price_sources_status
    r.price_sources_status := json_build_object(
        'live_price', json_build_object('value', v_live, 'weight', r.w_live, 'active', v_live IS NOT NULL AND v_live > 0),
        'market_price', json_build_object('value', v_market_price, 'weight', r.w_market, 'active', v_market_price IS NOT NULL AND v_market_price > 0),
        'ai_price', json_build_object('value', v_ai, 'weight', r.w_ai, 'active', v_ai IS NOT NULL AND v_ai > 0)
    );

    -- 5. stability_flag
    IF v_old_mark IS NOT NULL AND r.mark_price IS NOT NULL AND v_old_mark > 0 THEN
        IF ABS(r.mark_price - v_old_mark) / v_old_mark > 0.25 THEN
            r.stability_flag := 'CAPPED';  -- 被防抖限制
        ELSIF ABS(r.mark_price - v_old_mark) / v_old_mark > 0.10 THEN
            r.stability_flag := 'SMOOTHED';  -- EMA 平滑生效
        ELSE
            r.stability_flag := 'STABLE';
        END IF;
    ELSE
        r.stability_flag := 'INITIAL';
    END IF;

    RETURN r;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.get_mark_price_with_explanation IS '返回 mark_price 完整解释（权重/活跃度/稳定性）';

-- ── 7. 主触发器：价格变动时自动计算 mark_price ───────────────────────────

CREATE OR REPLACE FUNCTION public.update_mark_price_on_change()
RETURNS TRIGGER AS $$
DECLARE
    v_activity_score NUMERIC(5,4);
    v_w_live NUMERIC(5,4);
    v_w_market NUMERIC(5,4);
    v_w_ai NUMERIC(5,4);
    v_new_mark NUMERIC(12,2);
BEGIN
    -- 1. 计算 activity_score
    v_activity_score := public.compute_activity_score(
        COALESCE(NEW.trade_count_24h, 0),
        COALESCE(NEW.volatility_24h, 0),
        COALESCE(NEW.unique_buyers_24h, 0)
    );

    -- 2. 计算动态权重
    SELECT out_w_live, out_w_market, out_w_ai
    INTO v_w_live, v_w_market, v_w_ai
    FROM public.compute_dynamic_weights(v_activity_score);

    -- 3. 保存旧值用于 EMA
    NEW.mark_price_prev := NEW.mark_price;

    -- 4. 计算 mark_price
    NEW.mark_price := public.compute_mark_price(
        NEW.live_price,
        NEW.market_price,
        NEW.ai_estimate_price,
        v_w_live,
        v_w_market,
        v_w_ai,
        NEW.mark_price
    );

    -- 5. 写回计算字段
    NEW.activity_score := v_activity_score;
    NEW.w_live := v_w_live;
    NEW.w_market := v_w_market;
    NEW.w_ai := v_w_ai;
    NEW.mark_price_updated_at := NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_update_mark_price ON public.card_market;
CREATE TRIGGER trg_update_mark_price
    BEFORE UPDATE OF live_price, market_price, ai_estimate_price,
                       trade_count_24h, volatility_24h, unique_buyers_24h
    ON public.card_market
    FOR EACH ROW
    EXECUTE FUNCTION public.update_mark_price_on_change();

COMMENT ON TRIGGER trg_update_mark_price ON public.card_market
    IS '价格/活跃度变动时自动重算 mark_price（含EMA+防抖）';

-- ── 8. RPC: refresh_all_mark_prices（批量刷新，供 price-updater 调用）───────────────────────────

CREATE OR REPLACE FUNCTION public.refresh_all_mark_prices(
    p_market TEXT DEFAULT NULL
) RETURNS TABLE(
    processed INTEGER,
    updated INTEGER,
    errors INTEGER
) AS $$
DECLARE
    r RECORD;
    v_count INTEGER := 0;
    v_updated INTEGER := 0;
    v_errors INTEGER := 0;
BEGIN
    FOR r IN
        SELECT id, card_name, series, rarity, market,
               live_price, market_price, ai_estimate_price,
               trade_count_24h, volatility_24h, unique_buyers_24h,
               mark_price
        FROM public.card_market
        WHERE (p_market IS NULL OR card_market.market = p_market)
        ORDER BY final_price DESC
    LOOP
        v_count := v_count + 1;
        BEGIN
            UPDATE public.card_market
            SET live_price = r.live_price  -- 触发 BEFORE UPDATE 触发器
            WHERE id = r.id;
            v_updated := v_updated + 1;
        EXCEPTION WHEN OTHERS THEN
            v_errors := v_errors + 1;
        END;
    END LOOP;

    processed := v_count;
    updated := v_updated;
    errors := v_errors;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.refresh_all_mark_prices IS '批量刷新所有卡的 mark_price（触发触发器重算）';

-- ── 9. 初始化现有数据的 mark_price ───────────────────────────

UPDATE public.card_market
SET live_price = live_price  -- 触发触发器
WHERE mark_price IS NULL;

-- ── 10. 验证视图 ───────────────────────────

CREATE OR REPLACE VIEW public.v_mark_price_diagnostic AS
SELECT
    card_name,
    series,
    rarity,
    market,
    live_price,
    market_price,
    ai_estimate_price,
    final_price,
    activity_score,
    w_live,
    w_market,
    w_ai,
    mark_price,
    mark_price_prev,
    CASE
        WHEN activity_score >= 0.7 THEN 'high'
        WHEN activity_score >= 0.3 THEN 'medium'
        ELSE 'low'
    END AS activity_level,
    mark_price_updated_at
FROM public.card_market
ORDER BY mark_price DESC NULLS LAST;

COMMENT ON VIEW public.v_mark_price_diagnostic IS 'mark_price 诊断视图（含权重/活跃度/EMA状态）';

DO $$ BEGIN RAISE NOTICE 'P8 动态权重市场定价引擎已部署。card_market 新增 activity_score/w_live/w_market/w_ai/mark_price 等列，触发器自动计算 mark_price。'; END $$;
