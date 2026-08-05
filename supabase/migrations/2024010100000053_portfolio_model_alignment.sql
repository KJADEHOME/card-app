-- TASK-CR-0104-P: align portfolio_items -> user_portfolio aggregation.
-- Preserves the existing four-column RPC return signature for compatibility.

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.refresh_user_portfolio(uuid)') IS NULL THEN
    RAISE EXCEPTION '0053 requires public.refresh_user_portfolio(uuid)';
  END IF;
  IF to_regclass('public.portfolio_items') IS NULL
     OR to_regclass('public.user_portfolio') IS NULL THEN
    RAISE EXCEPTION '0053 requires portfolio_items and user_portfolio';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM (VALUES
      ('card_count'), ('total_quantity'), ('total_cost'),
      ('total_asset_value'), ('profit_loss'), ('profit_percent')
    ) AS required(column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns AS c
      WHERE c.table_schema = 'public'
        AND c.table_name = 'user_portfolio'
        AND c.column_name = required.column_name
    )
  ) THEN
    RAISE EXCEPTION '0053 requires all aligned user_portfolio columns';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_user_portfolio(p_user_id UUID)
RETURNS TABLE(
  out_total_value NUMERIC,
  out_total_cost NUMERIC,
  out_profit NUMERIC,
  out_profit_pct NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_card_count INTEGER := 0;
  v_total_quantity INTEGER := 0;
  v_total_value NUMERIC := 0;
  v_total_cost NUMERIC := 0;
  v_profit NUMERIC := 0;
  v_profit_pct NUMERIC := 0;
BEGIN
  SELECT
    COUNT(*)::INTEGER,
    COALESCE(SUM(pi.quantity), 0)::INTEGER,
    COALESCE(SUM(pi.current_price * pi.quantity), 0),
    COALESCE(SUM(pi.total_cost), 0)
  INTO
    v_card_count,
    v_total_quantity,
    v_total_value,
    v_total_cost
  FROM public.portfolio_items AS pi
  WHERE pi.user_id = p_user_id;

  v_profit := v_total_value - v_total_cost;
  v_profit_pct := CASE
    WHEN v_total_cost > 0 THEN ROUND(v_profit / v_total_cost * 100, 2)
    ELSE 0
  END;

  INSERT INTO public.user_portfolio (
    user_id,
    card_count,
    total_quantity,
    total_cost,
    total_asset_value,
    profit_loss,
    profit_percent,
    updated_at
  ) VALUES (
    p_user_id,
    v_card_count,
    v_total_quantity,
    v_total_cost,
    v_total_value,
    v_profit,
    v_profit_pct,
    NOW()
  )
  ON CONFLICT (user_id)
  DO UPDATE SET
    card_count = EXCLUDED.card_count,
    total_quantity = EXCLUDED.total_quantity,
    total_cost = EXCLUDED.total_cost,
    total_asset_value = EXCLUDED.total_asset_value,
    profit_loss = EXCLUDED.profit_loss,
    profit_percent = EXCLUDED.profit_percent,
    updated_at = EXCLUDED.updated_at;

  out_total_value := v_total_value;
  out_total_cost := v_total_cost;
  out_profit := v_profit;
  out_profit_pct := v_profit_pct;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.refresh_user_portfolio(UUID) IS
  'CR-0104-P: aggregate card count, quantity, cost, asset value and profit from portfolio_items.';

COMMIT;
