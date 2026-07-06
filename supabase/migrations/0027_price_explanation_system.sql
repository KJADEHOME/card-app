-- Phase 8.5: 价格解释系统 + 市场状态标签
-- 目标：构建"市场可视化 + 用户理解层"

-- ===== 1. card_market 新增解释列 =====

ALTER TABLE card_market 
ADD COLUMN IF NOT EXISTS price_explanation TEXT,
ADD COLUMN IF NOT EXISTS price_reason_tags TEXT[],
ADD COLUMN IF NOT EXISTS market_state TEXT DEFAULT 'COLD' CHECK (market_state IN ('HOT','NORMAL','COLD')),
ADD COLUMN IF NOT EXISTS last_explanation_update TIMESTAMPTZ DEFAULT NOW();

COMMENT ON COLUMN card_market.price_explanation IS '价格变化解释文本（用户可读）';
COMMENT ON COLUMN card_market.price_reason_tags IS '价格变化原因标签数组，如 {volume_surge,buyer_inflow}';
COMMENT ON COLUMN card_market.market_state IS '市场状态：HOT(>0.7) / NORMAL(0.3~0.7) / COLD(<0.3)';

-- ===== 2. price_explanation 生成函数 =====

CREATE OR REPLACE FUNCTION generate_price_explanation(
  p_card_name TEXT,
  p_series TEXT DEFAULT '',
  p_rarity TEXT DEFAULT 'N',
  p_market TEXT DEFAULT 'CN'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_card RECORD;
  v_prev_price NUMERIC;
  v_change_pct NUMERIC;
  v_explanation TEXT := '';
  v_reason_tags TEXT[] := '{}';
  v_market_state TEXT := 'COLD';
  v_activity_score NUMERIC := 0;
  v_result JSONB;
BEGIN
  -- 获取卡牌数据
  SELECT 
    cm.final_price,
    cm.mark_price,
    cm.activity_score,
    cm.trade_count_24h,
    cm.volatility_24h,
    cm.unique_buyers_24h,
    cm.price_explanation,
    cm.price_reason_tags,
    cm.market_state
  INTO v_card
  FROM card_market cm
  WHERE cm.card_name = p_card_name 
    AND cm.series = p_series 
    AND cm.rarity = p_rarity 
    AND cm.market = p_market;

  IF v_card IS NULL THEN
    RETURN jsonb_build_object('error', 'card not found');
  END IF;

  v_activity_score := COALESCE(v_card.activity_score, 0);

  -- 确定市场状态
  IF v_activity_score >= 0.7 THEN
    v_market_state := 'HOT';
  ELSIF v_activity_score >= 0.3 THEN
    v_market_state := 'NORMAL';
  ELSE
    v_market_state := 'COLD';
  END IF;

  -- 生成解释（基于模拟数据，实际应从 price_change_events 获取）
  -- 这里生成结构化解释
  IF v_card.final_price IS NOT NULL AND v_card.mark_price IS NOT NULL THEN
    v_change_pct := CASE 
      WHEN v_card.mark_price > 0 
      THEN ((v_card.final_price - v_card.mark_price) / v_card.mark_price * 100)
      ELSE 0 
    END;

    -- 生成原因标签
    IF v_activity_score >= 0.7 THEN
      v_reason_tags := array_append(v_reason_tags, 'high_activity');
    END IF;

    IF COALESCE(v_card.trade_count_24h, 0) > 10 THEN
      v_reason_tags := array_append(v_reason_tags, 'high_volume');
    END IF;

    IF COALESCE(v_card.volatility_24h, 0) > 0.05 THEN
      v_reason_tags := array_append(v_reason_tags, 'high_volatility');
    END IF;

    IF COALESCE(v_card.unique_buyers_24h, 0) > 5 THEN
      v_reason_tags := array_append(v_reason_tags, 'buyer_inflow');
    END IF;

    -- 生成解释文本
    IF v_change_pct > 5 THEN
      v_explanation := format('价格较昨日上涨 %.1f%%，市场活跃度 %s', 
        v_change_pct, 
        CASE 
          WHEN v_market_state = 'HOT' THEN '🔥 高热度'
          WHEN v_market_state = 'NORMAL' THEN '📈 正常'
          ELSE '📊 偏低'
        END
      );
      v_reason_tags := array_append(v_reason_tags, 'price_up');
    ELSIF v_change_pct < -5 THEN
      v_explanation := format('价格较昨日下跌 %.1f%%，市场活跃度 %s', 
        ABS(v_change_pct), 
        CASE 
          WHEN v_market_state = 'HOT' THEN '🔥 高热度'
          WHEN v_market_state = 'NORMAL' THEN '📉 正常'
          ELSE '📊 偏低'
        END
      );
      v_reason_tags := array_append(v_reason_tags, 'price_down');
    ELSE
      v_explanation := format('价格稳定，市场活跃度 %s', 
        CASE 
          WHEN v_market_state = 'HOT' THEN '🔥 高热度'
          WHEN v_market_state = 'NORMAL' THEN '📊 正常'
          ELSE '❄️  偏低'
        END
      );
      v_reason_tags := array_append(v_reason_tags, 'stable');
    END IF;

    -- 添加市场状态说明
    IF v_market_state = 'HOT' THEN
      v_explanation := v_explanation || '。交易活跃，建议关注价格波动。';
    ELSIF v_market_state = 'COLD' THEN
      v_explanation := v_explanation || '。市场交易较少，价格相对稳定。';
    END IF;

  ELSE
    v_explanation := '暂无足够价格数据生成解释。';
    v_reason_tags := array_append(v_reason_tags, 'insufficient_data');
  END IF;

  -- 更新 card_market
  UPDATE card_market
  SET 
    price_explanation = v_explanation,
    price_reason_tags = v_reason_tags,
    market_state = v_market_state,
    last_explanation_update = NOW()
  WHERE card_name = p_card_name 
    AND series = p_series 
    AND rarity = p_rarity 
    AND market = p_market;

  -- 返回结果
  v_result := jsonb_build_object(
    'card_name', p_card_name,
    'mark_price', v_card.mark_price,
    'final_price', v_card.final_price,
    'change_percent', ROUND(v_change_pct, 2),
    'explanation', v_explanation,
    'reason_tags', v_reason_tags,
    'market_state', v_market_state,
    'activity_score', v_activity_score
  );

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION generate_price_explanation(TEXT,TEXT,TEXT,TEXT) IS 
'生成卡牌价格解释和市场状态标签';

-- ===== 3. 批量更新所有卡牌解释 =====

CREATE OR REPLACE FUNCTION refresh_all_price_explanations(
  p_market TEXT DEFAULT 'CN'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_card RECORD;
  v_count INT := 0;
  v_result JSONB;
BEGIN
  FOR v_card IN 
    SELECT card_name, series, rarity 
    FROM card_market 
    WHERE market = p_market
  LOOP
    PERFORM generate_price_explanation(v_card.card_name, v_card.series, v_card.rarity, p_market);
    v_count := v_count + 1;
  END LOOP;

  v_result := jsonb_build_object(
    'success', TRUE,
    'cards_updated', v_count,
    'market', p_market
  );

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION refresh_all_price_explanations(TEXT) IS 
'批量更新所有卡牌的价格解释和市场状态';

-- ===== 4. 市场状态统计视图 =====

CREATE OR REPLACE VIEW market_state_overview AS
SELECT 
  market,
  market_state,
  COUNT(*) as card_count,
  AVG(activity_score) as avg_activity,
  AVG(final_price) as avg_price,
  MAX(last_explanation_update) as last_update
FROM card_market
WHERE market_state IS NOT NULL
GROUP BY market, market_state
ORDER BY market, 
  CASE market_state 
    WHEN 'HOT' THEN 1 
    WHEN 'NORMAL' THEN 2 
    WHEN 'COLD' THEN 3 
  END;

COMMENT ON VIEW market_state_overview IS 
'市场状态分布概览（用于 Market Feed 页面）';

-- ===== 5. 热门卡牌视图（用于 Market Feed） =====

CREATE OR REPLACE VIEW hot_cards_feed AS
SELECT 
  cm.card_name,
  cm.series,
  cm.rarity,
  cm.market,
  cm.final_price,
  cm.mark_price,
  cm.activity_score,
  cm.market_state,
  cm.price_explanation,
  cm.price_reason_tags,
  cm.trade_count_24h,
  cm.volatility_24h,
  CASE 
    WHEN cm.mark_price > 0 
    THEN ROUND(((cm.final_price - cm.mark_price) / cm.mark_price * 100)::NUMERIC, 2)
    ELSE 0 
  END as change_percent,
  cm.last_explanation_update
FROM card_market cm
WHERE cm.market = 'CN'
ORDER BY 
  CASE cm.market_state 
    WHEN 'HOT' THEN 1 
    WHEN 'NORMAL' THEN 2 
    WHEN 'COLD' THEN 3 
  END,
  cm.activity_score DESC,
  cm.final_price DESC
LIMIT 50;

COMMENT ON VIEW hot_cards_feed IS 
'热门卡牌 Feed（用于 market_feed.html）';

-- ===== 6. 触发器：自动更新 market_state =====

CREATE OR REPLACE FUNCTION update_market_state()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 当 activity_score 变化时，自动更新 market_state
  IF NEW.activity_score IS DISTINCT FROM OLD.activity_score 
     OR NEW.activity_score IS NOT NULL AND OLD.activity_score IS NULL
     OR NEW.activity_score IS NULL AND OLD.activity_score IS NOT NULL
  THEN
    NEW.market_state := CASE 
      WHEN NEW.activity_score >= 0.7 THEN 'HOT'
      WHEN NEW.activity_score >= 0.3 THEN 'NORMAL'
      ELSE 'COLD'
    END;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_update_market_state ON card_market;

CREATE TRIGGER trg_update_market_state
BEFORE INSERT OR UPDATE OF activity_score ON card_market
FOR EACH ROW
EXECUTE FUNCTION update_market_state();

COMMENT ON TRIGGER trg_update_market_state ON card_market IS 
'自动根据 activity_score 更新 market_state';

-- ===== 7. 初始化现有数据 =====

-- 更新现有卡的 market_state
UPDATE card_market
SET market_state = CASE 
  WHEN activity_score >= 0.7 THEN 'HOT'
  WHEN activity_score >= 0.3 THEN 'NORMAL'
  ELSE 'COLD'
END
WHERE market_state IS NULL;

-- 生成初始解释（批量）
-- SELECT refresh_all_price_explanations('CN');

-- ===== 8. 授权 =====

GRANT SELECT ON hot_cards_feed TO authenticated, anon;
GRANT SELECT ON market_state_overview TO authenticated, anon;
GRANT EXECUTE ON FUNCTION generate_price_explanation(TEXT,TEXT,TEXT,TEXT) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION refresh_all_price_explanations(TEXT) TO service_role;
