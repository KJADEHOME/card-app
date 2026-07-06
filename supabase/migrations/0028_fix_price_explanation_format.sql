-- Phase 8.5 修复：generate_price_explanation() format() 错误
-- 修复 PostgreSQL format() 不支持 %.1f 的问题

-- ===== 1. 删除旧函数 =====

DROP FUNCTION IF EXISTS generate_price_explanation(TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS refresh_all_price_explanations(TEXT);

-- ===== 2. 重新创建 generate_price_explanation() =====

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
  v_change_pct_text TEXT;
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

  -- 生成解释
  IF v_card.final_price IS NOT NULL AND v_card.mark_price IS NOT NULL THEN
    v_change_pct := CASE 
      WHEN v_card.mark_price > 0 
      THEN ((v_card.final_price - v_card.mark_price) / v_card.mark_price * 100)
      ELSE 0 
    END;
    
    v_change_pct_text := ROUND(v_change_pct, 1)::TEXT;

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

    -- 生成解释文本（使用正确的 format() 语法）
    IF v_change_pct > 5 THEN
      v_explanation := format('价格较昨日上涨 %s%%，市场活跃度 %s', 
        v_change_pct_text,
        CASE 
          WHEN v_market_state = 'HOT' THEN '🔥 高热度'
          WHEN v_market_state = 'NORMAL' THEN '📈 正常'
          ELSE '📊 偏低'
        END
      );
      v_reason_tags := array_append(v_reason_tags, 'price_up');
    ELSIF v_change_pct < -5 THEN
      v_explanation := format('价格较昨日下跌 %s%%，市场活跃度 %s', 
        ROUND(ABS(v_change_pct), 1)::TEXT,
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
'生成卡牌价格解释和市场状态标签（已修复 format() 错误）';

-- ===== 3. 重新创建 refresh_all_price_explanations() =====

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
'批量更新所有卡牌的价格解释和市场状态（已修复）';

-- ===== 4. 授权 =====

GRANT EXECUTE ON FUNCTION generate_price_explanation(TEXT,TEXT,TEXT,TEXT) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION refresh_all_price_explanations(TEXT) TO service_role;
