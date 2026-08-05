-- 迁移 0031: 修复 market_state 自动更新触发器
-- 问题：activity_score 已计算，但 market_state 未更新
-- 修复：创建触发器在函数计算 activity_score 后自动更新 market_state
-- 日期：2026-07-06

-- 创建或替换触发器函数
CREATE OR REPLACE FUNCTION public.update_market_state_from_activity()
RETURNS TRIGGER AS $$
BEGIN
  -- 根据 activity_score 更新 market_state
  IF NEW.activity_score IS NULL THEN
    NEW.market_state := 'COLD';
  ELSIF NEW.activity_score > 0.7 THEN
    NEW.market_state := 'HOT';
  ELSIF NEW.activity_score >= 0.3 AND NEW.activity_score <= 0.7 THEN
    NEW.market_state := 'NORMAL';
  ELSE
    NEW.market_state := 'COLD';
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 创建 BEFORE UPDATE 触发器（在 compute_mark_price 之后执行）
-- 注意：需要确保此触发器在 compute_mark_price 之后执行
-- PostgreSQL 按触发器名称字母顺序执行 BEFORE 触发器
-- 所以命名为 trg_z_update_market_state（在 trg_update_mark_price 之后）

CREATE OR REPLACE TRIGGER trg_z_update_market_state
  BEFORE UPDATE OF activity_score ON public.card_market
  FOR EACH ROW
  EXECUTE FUNCTION public.update_market_state_from_activity();

-- 验证：查询几张卡确认 market_state 是否正确
COMMENT ON TRIGGER trg_z_update_market_state ON public.card_market
IS '自动根据 activity_score 更新 market_state（在 compute_mark_price 之后执行）';
