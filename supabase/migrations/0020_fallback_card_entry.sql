-- ============================================================
-- 0020_fallback_card_entry.sql — AI识卡 Fallback 系统
-- 核心原则：AI失败 ≠ 失败流程，所有卡必须能进入系统
-- ============================================================

-- 1. 统一卡牌入库 RPC（AI扫描/手动录入/Fallback共用）
-- 原子操作：写入 user_collections + scan_history + ai_scan_logs + 扣积分
CREATE OR REPLACE FUNCTION public.complete_card_entry(
  p_user_id UUID,
  p_card_name TEXT,
  p_series TEXT DEFAULT '',
  p_rarity TEXT DEFAULT 'N',
  p_card_image TEXT DEFAULT NULL,
  p_purchase_price NUMERIC(12,2) DEFAULT 0,
  p_current_price NUMERIC(12,2) DEFAULT 0,
  p_card_category TEXT DEFAULT 'other',
  p_source TEXT DEFAULT 'AI_SCAN',  -- AI_SCAN | MANUAL | FALLBACK
  p_scan_type TEXT DEFAULT 'camera', -- camera | upload
  p_image_hash TEXT DEFAULT NULL,
  p_card_type TEXT DEFAULT NULL,     -- TCG | NON_TCG | UNKNOWN | ERROR
  p_game TEXT DEFAULT NULL,
  p_confidence NUMERIC(3,2) DEFAULT 0,
  p_suggested_cards JSONB DEFAULT '[]'::jsonb,
  p_ai_reason TEXT DEFAULT NULL,
  p_ai_failed BOOLEAN DEFAULT FALSE  -- AI是否失败（失败时不扣积分）
)
RETURNS TABLE(
  success BOOLEAN,
  collection_id UUID,
  scan_history_id UUID,
  scan_log_id UUID,
  points_cost INTEGER,
  points_discounted INTEGER,
  error TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_collection_id UUID;
  v_scan_history_id UUID;
  v_scan_log_id UUID;
  v_points_cost INTEGER := 0;
  v_points_discounted INTEGER := 0;
  v_points_base INTEGER := 10;
  v_user_points INTEGER := 0;
  v_user_level INTEGER := 1;
  v_discount_pct INTEGER := 0;
  v_dup_count INTEGER := 0;
  v_can_scan BOOLEAN := true;
  v_rate_error TEXT := '';
BEGIN
  -- ============================================================
  -- Step 1: 图片去重检查（同一用户 + 同一图片哈希，24小时内）
  -- ============================================================
  IF p_image_hash IS NOT NULL AND p_image_hash != '' THEN
    SELECT COUNT(*) INTO v_dup_count
    FROM public.ai_scan_logs
    WHERE user_id = p_user_id
      AND image_hash = p_image_hash
      AND created_at >= NOW() - INTERVAL '24 hours';

    IF v_dup_count > 0 THEN
      RETURN QUERY SELECT FALSE, NULL::UUID, NULL::UUID, NULL::UUID, 0, 0, '该图片24小时内已扫描过，请勿重复识卡';
      RETURN;
    END IF;
  END IF;

  -- ============================================================
  -- Step 2: 风控 + 频率检查（AI失败时跳过）
  -- ============================================================
  IF NOT p_ai_failed THEN
    BEGIN
      SELECT can_scan, error_msg INTO v_can_scan, v_rate_error
      FROM public.check_ai_rate_limit(p_user_id)
      LIMIT 1;

      IF NOT v_can_scan THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::UUID, NULL::UUID, 0, 0, COALESCE(v_rate_error, '频率限制');
        RETURN;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- 风控检查失败不阻断流程
    END;
  END IF;

  -- ============================================================
  -- Step 3: 积分计算（AI失败时免扣积分）
  -- ============================================================
  IF NOT p_ai_failed THEN
    BEGIN
      SELECT current_points, COALESCE(level, 1) INTO v_user_points, v_user_level
      FROM public.user_points
      WHERE user_id = p_user_id
      LIMIT 1;

      IF v_user_points < v_points_base THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::UUID, NULL::UUID, 0, 0, '积分不足';
        RETURN;
      END IF;

      BEGIN
        SELECT COALESCE(scan_discount_pct, 0) INTO v_discount_pct
        FROM public.level_config
        WHERE level = v_user_level
        LIMIT 1;
      EXCEPTION WHEN OTHERS THEN
        v_discount_pct := 0;
      END;

      v_points_discounted := FLOOR(v_points_base * v_discount_pct / 100);
      v_points_cost := v_points_base - v_points_discounted;
    EXCEPTION WHEN OTHERS THEN
      -- 积分表不存在等情况，不扣积分
      v_points_cost := 0;
    END;
  END IF;

  -- ============================================================
  -- Step 4: 写入 user_collections
  -- ============================================================
  INSERT INTO public.user_collections (
    user_id, card_name, card_name_en, card_image, series, rarity,
    card_category, condition, purchase_price, purchase_currency,
    current_price, current_currency, purchase_date, quantity, source
  ) VALUES (
    p_user_id, p_card_name, p_card_name, p_card_image, p_series, p_rarity,
    p_card_category, 'NM', p_purchase_price, 'CNY',
    CASE WHEN p_current_price > 0 THEN p_current_price ELSE p_purchase_price END, 'CNY',
    CURRENT_DATE, 1, p_source
  )
  RETURNING id INTO v_collection_id;

  -- ============================================================
  -- Step 5: Upsert card_prices（如果有估价）
  -- ============================================================
  IF p_current_price > 0 THEN
    BEGIN
      INSERT INTO public.card_prices (
        card_name, series, rarity, card_category,
        current_price, previous_price, change_percent,
        market, currency, data_source, updated_at
      ) VALUES (
        p_card_name, p_series, p_rarity, p_card_category,
        p_current_price, NULL, 0,
        'CN', 'CNY', 'tcgdex', NOW()
      )
      ON CONFLICT (card_name, series, rarity, market)
      DO UPDATE SET
        current_price = EXCLUDED.current_price,
        updated_at = NOW();
    EXCEPTION WHEN OTHERS THEN
      -- card_prices 写入失败不阻断
    END;
  END IF;

  -- ============================================================
  -- Step 6: 写入 scan_history（含 0017 新增字段）
  -- ============================================================
  INSERT INTO public.scan_history (
    user_id, card_name, card_name_en, card_image, series, rarity,
    estimated_price, estimated_currency, ai_confidence, scan_type,
    image_hash, collection_id, card_type, game, suggested_cards
  ) VALUES (
    p_user_id, p_card_name, p_card_name, p_card_image, p_series, p_rarity,
    p_current_price, 'CNY', p_confidence, p_scan_type,
    p_image_hash, v_collection_id, p_card_type, p_game, p_suggested_cards
  )
  RETURNING id INTO v_scan_history_id;

  -- ============================================================
  -- Step 7: 写入 ai_scan_logs（防刷记录，含 0017 新增字段）
  -- ============================================================
  INSERT INTO public.ai_scan_logs (
    user_id, image_hash, card_name, series, rarity,
    collection_id, scan_history_id,
    points_cost, points_discounted, points_base,
    card_type, confidence
  ) VALUES (
    p_user_id, COALESCE(p_image_hash, 'nohash_' || EXTRACT(EPOCH FROM NOW())::TEXT),
    p_card_name, p_series, p_rarity,
    v_collection_id, v_scan_history_id,
    v_points_cost, v_points_discounted, v_points_base,
    p_card_type, p_confidence
  )
  RETURNING id INTO v_scan_log_id;

  -- ============================================================
  -- Step 8: 扣除积分（原子操作）
  -- ============================================================
  IF v_points_cost > 0 THEN
    BEGIN
      PERFORM public.deduct_scan_points(
        p_user_id, v_points_cost, p_card_name, v_scan_log_id
      );
    EXCEPTION WHEN OTHERS THEN
      -- 积分扣除失败不阻断流程
    END;
  END IF;

  -- ============================================================
  -- 返回结果
  -- ============================================================
  RETURN QUERY SELECT TRUE, v_collection_id, v_scan_history_id, v_scan_log_id, v_points_cost, v_points_discounted, NULL::TEXT;
END;
$$;

-- 权限：认证用户可以调用
GRANT EXECUTE ON FUNCTION public.complete_card_entry TO authenticated;

-- ============================================================
-- 2. 更新 deduct_scan_points 使其接受 scan_log_id（而非 collection_id）
-- ============================================================
-- 注意：原有 deduct_scan_points 的 p_scan_log_id 参数实际接收的是 collection_id
-- 现在统一传 ai_scan_logs.id
-- 不需要修改函数定义，只需调用方传正确的值

-- ============================================================
-- 3. 更新 user_collections source 约束，增加 FALLBACK
-- ============================================================
-- 原有 source 没有 CHECK 约束，这里不添加约束保持灵活性
-- 新增 FALLBACK source 用于 AI 失败但用户手动录入的情况

-- ============================================================
-- 4. 创建索引优化查询
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_ai_scan_logs_user_hash_time
  ON public.ai_scan_logs (user_id, image_hash, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_scan_history_user_created
  ON public.scan_history (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_collections_user_created
  ON public.user_collections (user_id, created_at DESC);
