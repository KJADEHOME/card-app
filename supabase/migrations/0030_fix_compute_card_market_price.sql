-- 迁移 0030: 修复 compute_card_market_price 触发器函数
-- 问题：当所有价格源为 NULL 时，final_price 被重置为 0
-- 修复：保留原有的 final_price 值
-- 日期：2026-07-06

CREATE OR REPLACE FUNCTION public.compute_card_market_price()
RETURNS TRIGGER AS $$
DECLARE
  v_computed_price NUMERIC(12,2);
  v_computed_source TEXT;
BEGIN
  -- ============================================
  -- Step 1: 始终计算 unlocked_price（live > market > ai 优先级）
  -- 即使锁定时也计算，用于波动检测和锁定决策
  -- ============================================
  IF NEW.live_price IS NOT NULL AND NEW.live_price > 0 THEN
    v_computed_price := NEW.live_price;
    v_computed_source := 'live';
  ELSIF NEW.market_price IS NOT NULL AND NEW.market_price > 0 THEN
    v_computed_price := NEW.market_price;
    v_computed_source := 'market';
  ELSIF NEW.ai_estimate_price IS NOT NULL AND NEW.ai_estimate_price > 0 THEN
    v_computed_price := NEW.ai_estimate_price;
    v_computed_source := 'ai';
  ELSE
    -- 修复：保留原有的 final_price，而不是设置为 0
    v_computed_price := COALESCE(NEW.final_price, 0);
    v_computed_source := COALESCE(NEW.price_source, 'manual');
  END IF;

  NEW.unlocked_price := v_computed_price;
  NEW.price_source := v_computed_source;  -- price_source 始终反映底层来源

  -- ============================================
  -- Step 2: 根据锁定状态决定 final_price
  -- ============================================

  -- Case A: 锁定已过期 → 自动解锁
  IF NEW.price_locked = TRUE
     AND NEW.lock_expires_at IS NOT NULL
     AND NEW.lock_expires_at < NOW() THEN

    NEW.price_locked := FALSE;
    NEW.locked_price := NULL;
    NEW.lock_timestamp := NULL;
    NEW.lock_expires_at := NULL;
    NEW.lock_reason := NULL;
    NEW.final_price := v_computed_price;

  -- Case B: 锁定有效 → final_price = locked_price
  ELSIF NEW.price_locked = TRUE
        AND NEW.locked_price IS NOT NULL
        AND NEW.locked_price > 0 THEN

    NEW.final_price := NEW.locked_price;

  -- Case C: 未锁定 或 异常状态（locked=TRUE但无locked_price）→ 用 unlocked_price
  ELSE
    NEW.price_locked := FALSE;  -- 清理异常状态
    NEW.final_price := v_computed_price;
  END IF;

  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 验证修复：插入测试卡（无价格源）并验证 final_price 保留
-- 注意：需要在实际环境中测试
