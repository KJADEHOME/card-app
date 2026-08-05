-- 迁移 0029: 市场数据冷启动注入（Market Seeding）
-- 目的：注入模拟交易数据，让 activity_score 有真实值
-- 日期：2026-07-06

-- ============================================
-- 步骤1: 扩展卡牌数据到 50 张
-- ============================================

-- 先检查是否已有 seeding 标记，避免重复注入
CREATE TABLE IF NOT EXISTS public.system_flags (
  flag_name TEXT PRIMARY KEY,
  flag_value TEXT,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 如果已注入过，跳过插入新卡牌
DO $$
DECLARE
  v_already_seeded BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.system_flags WHERE flag_name = 'market_data_seeded'
  ) INTO v_already_seeded;

  IF NOT v_already_seeded THEN
    -- 插入 41 张新卡牌（加上现有 9 张 = 50 张）
    INSERT INTO public.card_market (card_name, series, rarity, market, final_price, mark_price, created_at, updated_at)
    VALUES
    -- Pokémon TCG (热门)
    ('Pikachu VMAX', 'Sword & Shield', 'Ultra Rare', 'CN', 899.00, 899.00, NOW(), NOW()),
    ('Pikachu ex', 'Scarlet & Violet', 'Special Illustration Rare', 'CN', 1299.00, 1299.00, NOW(), NOW()),
    ('Charizard ex', 'Paldean Fires', 'Ultra Rare', 'CN', 2199.00, 2199.00, NOW(), NOW()),
    ('Mew ex', '151', 'Ultra Rare', 'CN', 799.00, 799.00, NOW(), NOW()),
    ('Snorlax ex', 'Scarlet & Violet', 'Rare', 'CN', 459.00, 459.00, NOW(), NOW()),
    ('Blastoise ex', '151', 'Ultra Rare', 'CN', 1299.00, 1299.00, NOW(), NOW()),
    ('Venusaur ex', '151', 'Ultra Rare', 'CN', 1199.00, 1199.00, NOW(), NOW()),
    ('Mewtwo ex', '151', 'Ultra Rare', 'CN', 999.00, 999.00, NOW(), NOW()),
    ('Gyarados ex', 'Temporal Forces', 'Ultra Rare', 'CN', 699.00, 699.00, NOW(), NOW()),
    ('Lugia ex', 'Silver Tempest', 'Ultra Rare', 'CN', 1599.00, 1599.00, NOW(), NOW()),
    ('Rayquaza VMAX', 'Evolving Skies', 'Alternate Art', 'CN', 3999.00, 3999.00, NOW(), NOW()),
    ('Umbreon ex', 'Paldean Fires', 'Special Illustration Rare', 'CN', 3499.00, 3499.00, NOW(), NOW()),
    ('Sylveon ex', 'Paldean Fires', 'Ultra Rare', 'CN', 899.00, 899.00, NOW(), NOW()),
    ('Eevee ex', 'Paldean Fires', 'Ultra Rare', 'CN', 599.00, 599.00, NOW(), NOW()),
    ('Gengar ex', 'Paldean Fires', 'Special Illustration Rare', 'CN', 2899.00, 2899.00, NOW(), NOW()),
    ('Machamp ex', '151', 'Rare', 'CN', 399.00, 399.00, NOW(), NOW()),
    ('Alakazam ex', '151', 'Ultra Rare', 'CN', 799.00, 799.00, NOW(), NOW()),
    ('Golem ex', '151', 'Rare', 'CN', 349.00, 349.00, NOW(), NOW()),
    ('Ninetales ex', '151', 'Rare', 'CN', 499.00, 499.00, NOW(), NOW()),
    ('Rapidash ex', '151', 'Rare', 'CN', 299.00, 299.00, NOW(), NOW()),
    ('Dragonite ex', '151', 'Ultra Rare', 'CN', 999.00, 999.00, NOW(), NOW()),
    ('Articuno ex', '151', 'Ultra Rare', 'CN', 899.00, 899.00, NOW(), NOW()),
    ('Zapdos ex', '151', 'Ultra Rare', 'CN', 899.00, 899.00, NOW(), NOW()),
    ('Moltres ex', '151', 'Ultra Rare', 'CN', 899.00, 899.00, NOW(), NOW()),
    ('Mewtwo VSTAR', 'Crown Zenith', 'Ultra Rare', 'CN', 1299.00, 1299.00, NOW(), NOW()),
    ('Palkia VSTAR', 'Astral Radiance', 'Ultra Rare', 'CN', 1099.00, 1099.00, NOW(), NOW()),
    ('Dialga VSTAR', 'Astral Radiance', 'Ultra Rare', 'CN', 1099.00, 1099.00, NOW(), NOW()),
    ('Arceus VSTAR', 'Brilliant Stars', 'Ultra Rare', 'CN', 1899.00, 1899.00, NOW(), NOW()),
    ('Reshiram ex', 'Paldean Fires', 'Ultra Rare', 'CN', 799.00, 799.00, NOW(), NOW()),
    ('Zekrom ex', 'Paldean Fires', 'Ultra Rare', 'CN', 799.00, 799.00, NOW(), NOW()),
    ('Lucario ex', 'Temporal Forces', 'Ultra Rare', 'CN', 699.00, 699.00, NOW(), NOW()),
    ('Garchomp ex', 'Temporal Forces', 'Ultra Rare', 'CN', 899.00, 899.00, NOW(), NOW()),
    ('Metagross ex', 'Temporal Forces', 'Rare', 'CN', 499.00, 499.00, NOW(), NOW()),
    ('Tyranitar ex', 'Temporal Forces', 'Ultra Rare', 'CN', 1299.00, 1299.00, NOW(), NOW()),
    ('Ho-Oh ex', 'Temporal Forces', 'Ultra Rare', 'CN', 1099.00, 1099.00, NOW(), NOW()),
    ('Lugia ex (延迟版)', 'Silver Tempest', 'Alternate Art', 'CN', 2299.00, 2299.00, NOW(), NOW()),
    ('Darkrai ex', 'Temporal Forces', 'Ultra Rare', 'CN', 899.00, 899.00, NOW(), NOW()),
    ('Yveltal ex', 'Temporal Forces', 'Ultra Rare', 'CN', 799.00, 799.00, NOW(), NOW()),
    ('Xerneas ex', 'Temporal Forces', 'Ultra Rare', 'CN', 699.00, 699.00, NOW(), NOW()),
    ('Salamence ex', 'Paldean Fires', 'Rare', 'CN', 599.00, 599.00, NOW(), NOW()),
    ('Metapod ex', 'Paldean Fires', 'Common', 'CN', 99.00, 99.00, NOW(), NOW()),
    ('Weedle ex', 'Paldean Fires', 'Common', 'CN', 49.00, 49.00, NOW(), NOW()),
    ('Kakuna ex', 'Paldean Fires', 'Common', 'CN', 79.00, 79.00, NOW(), NOW()),
    ('Pidgey ex', 'Paldean Fires', 'Common', 'CN', 89.00, 89.00, NOW(), NOW()),
    ('Rattata ex', 'Paldean Fires', 'Common', 'CN', 59.00, 59.00, NOW(), NOW()),
    ('Zubat ex', 'Paldean Fires', 'Common', 'CN', 69.00, 69.00, NOW(), NOW()),
    ('Geodude ex', 'Paldean Fires', 'Common', 'CN', 79.00, 79.00, NOW(), NOW()),
    ('Magnemite ex', 'Paldean Fires', 'Common', 'CN', 99.00, 99.00, NOW(), NOW());

    -- 标记已注入
    INSERT INTO public.system_flags (flag_name, flag_value) VALUES ('market_data_seeded', 'true');
    
    RAISE NOTICE '✅ 成功插入 41 张新卡牌，总共 50 张';
  ELSE
    RAISE NOTICE '⚠️ 市场数据已注入过，跳过插入新卡牌';
  END IF;
END $$;

-- ============================================
-- 步骤2: 注入模拟交易数据
-- ============================================

-- 创建注入函数（可重复执行）
CREATE OR REPLACE FUNCTION public.seed_market_trade_data(p_market TEXT DEFAULT 'CN')
RETURNS JSON AS $$
DECLARE
  v_total INT;
  v_hot_count INT;
  v_normal_count INT;
  v_cold_count INT;
  v_card RECORD;
  v_rand FLOAT;
  v_trade_count INT;
  v_volume NUMERIC;
  v_buyers INT;
  v_volatility NUMERIC;
  v_activity_score NUMERIC;
  v_market_state TEXT;
  v_updated_count INT := 0;
BEGIN
  -- 计算目标数量（10% HOT / 40% NORMAL / 50% COLD）
  SELECT COUNT(*) INTO v_total FROM public.card_market WHERE market = p_market;
  
  v_hot_count := GREATEST(1, FLOOR(v_total * 0.10));
  v_normal_count := GREATEST(1, FLOOR(v_total * 0.40));
  v_cold_count := v_total - v_hot_count - v_normal_count;
  
  RAISE NOTICE '目标分布: HOT=%, NORMAL=%, COLD=%', v_hot_count, v_normal_count, v_cold_count;
  
  -- 重置所有卡的活跃度数据（如果是重新注入）
  UPDATE public.card_market 
  SET 
    trade_count_24h = 0,
    volume_24h = 0,
    unique_buyers_24h = 0,
    volatility_24h = 0,
    activity_score = 0,
    market_state = 'COLD',
    live_price = NULL,
    market_price = NULL
  WHERE market = p_market;
  
  -- 为前 v_hot_count 张卡注入 HOT 数据
  FOR v_card IN 
    SELECT id, card_name, final_price FROM public.card_market 
    WHERE market = p_market 
    ORDER BY final_price DESC 
    LIMIT v_hot_count
  LOOP
    -- HOT: 高交易活跃度
    v_trade_count := FLOOR(RANDOM() * 50 + 50)::INT;  -- 50~100 笔
    v_volume := v_trade_count * v_card.final_price * (RANDOM() * 0.5 + 0.5);  -- 模拟交易量
    v_buyers := FLOOR(RANDOM() * 30 + 20)::INT;  -- 20~50 买家
    v_volatility := RANDOM() * 0.15 + 0.05;  -- 5%~20% 波动率
    
    UPDATE public.card_market SET
      trade_count_24h = v_trade_count,
      volume_24h = v_volume,
      unique_buyers_24h = v_buyers,
      volatility_24h = v_volatility,
      live_price = final_price * (1 + (RANDOM() * 0.1 - 0.05)),  -- ±5% 波动
      updated_at = NOW()
    WHERE id = v_card.id;
    
    v_updated_count := v_updated_count + 1;
  END LOOP;
  
  -- 为接下来的 v_normal_count 张卡注入 NORMAL 数据
  FOR v_card IN 
    SELECT id, card_name, final_price FROM public.card_market 
    WHERE market = p_market 
    ORDER BY final_price DESC 
    OFFSET v_hot_count 
    LIMIT v_normal_count
  LOOP
    -- NORMAL: 中等交易活跃度
    v_trade_count := FLOOR(RANDOM() * 20 + 10)::INT;  -- 10~30 笔
    v_volume := v_trade_count * v_card.final_price * (RANDOM() * 0.3 + 0.2);
    v_buyers := FLOOR(RANDOM() * 10 + 5)::INT;  -- 5~15 买家
    v_volatility := RANDOM() * 0.08 + 0.02;  -- 2%~10% 波动率
    
    UPDATE public.card_market SET
      trade_count_24h = v_trade_count,
      volume_24h = v_volume,
      unique_buyers_24h = v_buyers,
      volatility_24h = v_volatility,
      market_price = final_price * (1 + (RANDOM() * 0.06 - 0.03)),  -- ±3% 波动
      updated_at = NOW()
    WHERE id = v_card.id;
    
    v_updated_count := v_updated_count + 1;
  END LOOP;
  
  -- 剩余的 v_cold_count 张卡保持 COLD（低活跃度）
  FOR v_card IN 
    SELECT id, card_name, final_price FROM public.card_market 
    WHERE market = p_market 
    ORDER BY final_price DESC 
    OFFSET v_hot_count + v_normal_count
  LOOP
    -- COLD: 低交易活跃度
    v_trade_count := FLOOR(RANDOM() * 5)::INT;  -- 0~5 笔
    v_volume := v_trade_count * v_card.final_price * RANDOM() * 0.1;
    v_buyers := FLOOR(RANDOM() * 3)::INT;  -- 0~3 买家
    v_volatility := RANDOM() * 0.03;  -- 0%~3% 波动率
    
    UPDATE public.card_market SET
      trade_count_24h = v_trade_count,
      volume_24h = v_volume,
      unique_buyers_24h = v_buyers,
      volatility_24h = v_volatility,
      updated_at = NOW()
    WHERE id = v_card.id;
    
    v_updated_count := v_updated_count + 1;
  END LOOP;
  
  -- 触发 activity_score 和 mark_price 重新计算
  PERFORM public.refresh_all_mark_prices(p_market);
  
  -- 触发价格解释重新生成
  PERFORM public.refresh_all_price_explanations(p_market);
  
  -- 返回统计信息
  RETURN json_build_object(
    'success', TRUE,
    'total_cards', v_total,
    'hot_count', v_hot_count,
    'normal_count', v_normal_count,
    'cold_count', v_cold_count,
    'updated_count', v_updated_count,
    'message', '市场数据注入成功'
  );
  
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 执行注入
SELECT public.seed_market_trade_data('CN');

-- 验证分布
SELECT 
  market_state,
  COUNT(*) as card_count,
  ROUND(AVG(activity_score)::NUMERIC, 4) as avg_activity,
  ROUND(AVG(trade_count_24h)::NUMERIC, 2) as avg_trades,
  ROUND(AVG(volatility_24h)::NUMERIC, 4) as avg_volatility
FROM public.card_market 
WHERE market = 'CN'
GROUP BY market_state
ORDER BY 
  CASE market_state 
    WHEN 'HOT' THEN 1 
    WHEN 'NORMAL' THEN 2 
    WHEN 'COLD' THEN 3 
  END;
