-- P8.1: 让 portfolio_items 使用 mark_price 估值

-- 1. 升级 sync_market_to_portfolio 触发器
CREATE OR REPLACE FUNCTION public.sync_market_to_portfolio()
RETURNS TRIGGER AS $$
DECLARE
    v_card_name TEXT;
    v_series TEXT;
    v_rarity TEXT;
    v_market TEXT;
    v_mark_price NUMERIC(12,2);
BEGIN
    v_card_name := COALESCE(NEW.card_name, OLD.card_name);
    v_series    := COALESCE(NEW.series, OLD.series);
    v_rarity    := COALESCE(NEW.rarity, OLD.rarity);
    v_market    := COALESCE(NEW.market, OLD.market, 'CN');

    v_mark_price := NEW.mark_price;
    IF v_mark_price IS NULL OR v_mark_price <= 0 THEN
        v_mark_price := NEW.final_price;
    END IF;

    UPDATE public.portfolio_items
    SET current_price = v_mark_price,
        profit_loss   = ROUND((v_mark_price - avg_buy_price) * quantity, 2),
        profit_percent = CASE
            WHEN avg_buy_price > 0
            THEN ROUND((v_mark_price - avg_buy_price) / avg_buy_price * 100, 2)
            ELSE 0
        END
    WHERE card_name = v_card_name
      AND series    = v_series
      AND rarity    = v_rarity;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. 升级 refresh_user_portfolio
DROP FUNCTION IF EXISTS public.refresh_user_portfolio(UUID);

CREATE OR REPLACE FUNCTION public.refresh_user_portfolio(p_user_id UUID)
RETURNS TABLE(
    out_total_value NUMERIC,
    out_total_cost  NUMERIC,
    out_profit      NUMERIC,
    out_profit_pct  NUMERIC
) AS $$
DECLARE
    v_total_value NUMERIC(12,2) := 0;
    v_total_cost  NUMERIC(12,2) := 0;
    v_profit      NUMERIC(12,2) := 0;
BEGIN
    SELECT
        COALESCE(SUM(COALESCE(cm.mark_price, cm.final_price) * pi.quantity), 0),
        COALESCE(SUM(pi.avg_buy_price * pi.quantity), 0),
        COALESCE(SUM((COALESCE(cm.mark_price, cm.final_price) - pi.avg_buy_price) * pi.quantity), 0)
    INTO v_total_value, v_total_cost, v_profit
    FROM public.portfolio_items pi
    LEFT JOIN public.card_market cm
        ON  cm.card_name = pi.card_name
        AND cm.series    = pi.series
        AND cm.rarity    = pi.rarity
    WHERE pi.user_id = p_user_id;

    INSERT INTO public.user_portfolio (user_id, total_asset_value, total_cost, profit_loss, profit_percent, updated_at)
    VALUES (
        p_user_id, v_total_value, v_total_cost, v_profit,
        CASE WHEN v_total_cost > 0 THEN ROUND(v_profit / v_total_cost * 100, 2) ELSE 0 END,
        NOW()
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
        total_asset_value = EXCLUDED.total_asset_value,
        total_cost      = EXCLUDED.total_cost,
        profit_loss     = EXCLUDED.profit_loss,
        profit_percent  = EXCLUDED.profit_percent,
        updated_at      = EXCLUDED.updated_at;

    out_total_value := v_total_value;
    out_total_cost  := v_total_cost;
    out_profit      := v_profit;
    out_profit_pct  := CASE WHEN v_total_cost > 0 THEN ROUND(v_profit / v_total_cost * 100, 2) ELSE 0 END;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. 初始化：用 mark_price 重算现有持仓估值
UPDATE public.portfolio_items pi
SET current_price = COALESCE(cm.mark_price, cm.final_price),
    profit_loss   = ROUND((COALESCE(cm.mark_price, cm.final_price) - pi.avg_buy_price) * pi.quantity, 2),
    profit_percent = CASE
        WHEN pi.avg_buy_price > 0
        THEN ROUND((COALESCE(cm.mark_price, cm.final_price) - pi.avg_buy_price) / pi.avg_buy_price * 100, 2)
        ELSE 0
    END
FROM public.card_market cm
WHERE cm.card_name = pi.card_name
  AND cm.series    = pi.series
  AND cm.rarity    = pi.rarity;

DO $$ BEGIN RAISE NOTICE 'P8.1: portfolio_items 已切换到 mark_price 估值'; END $$;
