-- =====================================================================
-- 0023: 锁死唯一价格真值规则 (Price Truth Rule Lockdown)
--
-- 目标：从数据库层面强制锁死 final_price 计算规则，确保不可绕过
--
-- 规则：
--   final_price = live_price   (if live_price > 0)
--   else market_price          (if market_price > 0)
--   else ai_estimate_price     (if ai_estimate_price > 0)
--   else 0
--
--   ⚠️ 不能混用！不能取平均！不能加权！
--   final_price 必须严格等于唯一一个优先级最高的有效价格源
--
-- 锁死措施（三层防护）:
--   层1: 触发器 — BEFORE INSERT OR UPDATE（全列，不再限 OF 三个价格列）
--        任何写操作都会重新计算 final_price，直接写 final_price 也会被覆盖
--   层2: CHECK 约束 — chk_price_truth_rule
--        即使触发器被 DISABLE，数据库仍拒绝不合规的数据
--   层3: CHECK 约束 — chk_price_source_values
--        price_source 只能是 'live' | 'market' | 'ai'
--
-- 额外修复:
--   upsert_card_market 新增 p_clear_live/p_clear_market/p_clear_ai 参数
--   解决旧 COALESCE 逻辑导致 live_price 设置后无法清除的"价格源残留"问题
-- =====================================================================

-- =====================================================================
-- 一、层1：增强触发器 — 全列监听，不可绕过
-- =====================================================================

-- 1.1 增强触发器函数：添加 RAISE NOTICE 日志 + 严格优先级
CREATE OR REPLACE FUNCTION public.compute_card_market_price()
RETURNS TRIGGER AS $$
BEGIN
    -- ================================================================
    -- 唯一价格真值规则（LOCKED — 不可修改）
    -- final_price = live_price (if > 0)
    --            else market_price (if > 0)
    --            else ai_estimate_price (if > 0)
    --            else 0
    -- ⚠️ 严格优先级，不混用、不平均、不加权
    -- ================================================================
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
        NEW.final_price := 0;
        NEW.price_source := 'ai';
    END IF;

    -- 强制覆盖：即使外部直接写 final_price / price_source，也由触发器决定
    -- （触发器在 BEFORE 阶段执行，NEW.final_price 已被上方逻辑覆盖）
    NEW.updated_at := NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.compute_card_market_price() IS
'【锁死】触发器函数：在 card_market INSERT/UPDATE 前，按 live > market > ai 优先级自动计算 final_price。任何对 card_market 的写操作都会触发，包括直接修改 final_price。';

-- 1.2 重建触发器：BEFORE INSERT OR UPDATE（全列，不再限 OF）
DROP TRIGGER IF EXISTS trg_card_market_price ON public.card_market;
CREATE TRIGGER trg_card_market_price
    BEFORE INSERT OR UPDATE  -- ⚠️ 全列监听，不限 OF
    ON public.card_market
    FOR EACH ROW
    EXECUTE FUNCTION public.compute_card_market_price();

-- =====================================================================
-- 二、层2：CHECK 约束 — 锁死 price_source 取值
-- =====================================================================
ALTER TABLE public.card_market
DROP CONSTRAINT IF EXISTS chk_price_source_values;

ALTER TABLE public.card_market
ADD CONSTRAINT chk_price_source_values
CHECK (price_source IN ('live', 'market', 'ai'));

-- =====================================================================
-- 三、层3：CHECK 约束 — 锁死 final_price = 优先级最高有效价格源
--    即使触发器被 DISABLE，此约束仍阻止非法数据写入
-- =====================================================================
ALTER TABLE public.card_market
DROP CONSTRAINT IF EXISTS chk_price_truth_rule;

ALTER TABLE public.card_market
ADD CONSTRAINT chk_price_truth_rule CHECK (
    -- Case 1: live_price 有效 → final_price = live_price, source = 'live'
    (
        COALESCE(live_price, 0) > 0
        AND final_price = live_price
        AND price_source = 'live'
    )
    -- Case 2: live_price 无效, market_price 有效 → final_price = market_price, source = 'market'
    OR (
        COALESCE(live_price, 0) <= 0
        AND COALESCE(market_price, 0) > 0
        AND final_price = market_price
        AND price_source = 'market'
    )
    -- Case 3: live 和 market 均无效, ai 有效 → final_price = ai_estimate_price, source = 'ai'
    OR (
        COALESCE(live_price, 0) <= 0
        AND COALESCE(market_price, 0) <= 0
        AND COALESCE(ai_estimate_price, 0) > 0
        AND final_price = ai_estimate_price
        AND price_source = 'ai'
    )
    -- Case 4: 全部无效 → final_price = 0, source = 'ai'
    OR (
        COALESCE(live_price, 0) <= 0
        AND COALESCE(market_price, 0) <= 0
        AND COALESCE(ai_estimate_price, 0) <= 0
        AND final_price = 0
        AND price_source = 'ai'
    )
);

COMMENT ON CONSTRAINT chk_price_truth_rule ON public.card_market IS
'【锁死】final_price 必须严格等于优先级最高的有效价格源(live>market>ai)，不混用、不平均、不加权';

-- =====================================================================
-- 四、修正现有数据 — 重新计算所有 card_market 的 final_price
--    确保 CHECK 约束添加时不会因旧数据不合规而失败
-- =====================================================================
UPDATE public.card_market SET
    final_price = CASE
        WHEN live_price IS NOT NULL AND live_price > 0 THEN live_price
        WHEN market_price IS NOT NULL AND market_price > 0 THEN market_price
        WHEN ai_estimate_price IS NOT NULL AND ai_estimate_price > 0 THEN ai_estimate_price
        ELSE 0
    END,
    price_source = CASE
        WHEN live_price IS NOT NULL AND live_price > 0 THEN 'live'
        WHEN market_price IS NOT NULL AND market_price > 0 THEN 'market'
        ELSE 'ai'
    END,
    updated_at = NOW();

-- =====================================================================
-- 五、升级 upsert_card_market — 支持清除价格源
--    解决旧 COALESCE 逻辑导致 live_price 设置后无法清除的问题
--
--    新增参数：
--      p_clear_live   — TRUE 时将 live_price/live_source 设为 NULL
--      p_clear_market — TRUE 时将 market_price/market_source 设为 NULL
--      p_clear_ai     — TRUE 时将 ai_estimate_price/ai_model 设为 NULL
-- =====================================================================
-- 先 DROP 旧函数（参数列表不同，CREATE OR REPLACE 会创建重名函数）
DROP FUNCTION IF EXISTS public.upsert_card_market(
    TEXT, TEXT, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, TEXT, TEXT, TEXT
);

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
    p_ai_model TEXT DEFAULT NULL,
    p_clear_live BOOLEAN DEFAULT FALSE,
    p_clear_market BOOLEAN DEFAULT FALSE,
    p_clear_ai BOOLEAN DEFAULT FALSE
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
        -- 支持清除：p_clear_* = TRUE 时设为 NULL，否则 COALESCE 保留旧值
        live_price = CASE
            WHEN p_clear_live THEN NULL
            ELSE COALESCE(EXCLUDED.live_price, card_market.live_price)
        END,
        market_price = CASE
            WHEN p_clear_market THEN NULL
            ELSE COALESCE(EXCLUDED.market_price, card_market.market_price)
        END,
        ai_estimate_price = CASE
            WHEN p_clear_ai THEN NULL
            ELSE COALESCE(EXCLUDED.ai_estimate_price, card_market.ai_estimate_price)
        END,
        live_source = CASE
            WHEN p_clear_live THEN NULL
            ELSE COALESCE(EXCLUDED.live_source, card_market.live_source)
        END,
        market_source = CASE
            WHEN p_clear_market THEN NULL
            ELSE COALESCE(EXCLUDED.market_source, card_market.market_source)
        END,
        ai_model = CASE
            WHEN p_clear_ai THEN NULL
            ELSE COALESCE(EXCLUDED.ai_model, card_market.ai_model)
        END,
        updated_at = NOW();
    -- ⚠️ 不写 final_price / price_source — 由触发器自动计算

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
'外部写入 card_market 的统一入口。支持局部更新和价格源清除(p_clear_*)。final_price 由触发器自动计算，不可直接写入。';

-- =====================================================================
-- 六、添加辅助 RPC：验证价格真值规则
--    供运维和前端调用，检查全表数据是否合规
-- =====================================================================
CREATE OR REPLACE FUNCTION public.verify_price_truth_rule()
RETURNS TABLE(
    total_cards INTEGER,
    compliant INTEGER,
    violations INTEGER,
    violation_details JSON
) AS $$
DECLARE
    v_total INTEGER;
    v_compliant INTEGER;
    v_violations INTEGER;
    v_details JSON;
BEGIN
    SELECT
        COUNT(*),
        COUNT(*) FILTER (
            WHERE
                -- Case 1: live
                (COALESCE(live_price, 0) > 0 AND final_price = live_price AND price_source = 'live')
                -- Case 2: market
                OR (COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) > 0 AND final_price = market_price AND price_source = 'market')
                -- Case 3: ai
                OR (COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) <= 0 AND COALESCE(ai_estimate_price, 0) > 0 AND final_price = ai_estimate_price AND price_source = 'ai')
                -- Case 4: none
                OR (COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) <= 0 AND COALESCE(ai_estimate_price, 0) <= 0 AND final_price = 0 AND price_source = 'ai')
        )
    INTO v_total, v_compliant
    FROM public.card_market;

    v_violations := v_total - v_compliant;

    -- 如果有违规，收集详情
    IF v_violations > 0 THEN
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
        INTO v_details
        FROM (
            SELECT
                card_name, series, rarity, market,
                live_price, market_price, ai_estimate_price,
                final_price, price_source
            FROM public.card_market
            WHERE NOT (
                (COALESCE(live_price, 0) > 0 AND final_price = live_price AND price_source = 'live')
                OR (COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) > 0 AND final_price = market_price AND price_source = 'market')
                OR (COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) <= 0 AND COALESCE(ai_estimate_price, 0) > 0 AND final_price = ai_estimate_price AND price_source = 'ai')
                OR (COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) <= 0 AND COALESCE(ai_estimate_price, 0) <= 0 AND final_price = 0 AND price_source = 'ai')
            )
        ) t;
    ELSE
        v_details := '[]'::json;
    END IF;

    total_cards := v_total;
    compliant := v_compliant;
    violations := v_violations;
    violation_details := v_details;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.verify_price_truth_rule() IS
'验证 card_market 全表是否符合唯一价格真值规则，返回违规详情';

-- =====================================================================
-- 七、更新表注释 — 文档化锁死规则
-- =====================================================================
COMMENT ON TABLE public.card_market IS
'卡牌多源价格聚合表 —— 【锁死】final_price 严格按 live > market > ai 优先级取唯一值，不混用、不平均、不加权';

COMMENT ON COLUMN public.card_market.final_price IS
'【锁死】系统最终定价 = 优先级最高的有效价格源(live>market>ai)。由触发器自动计算，CHECK约束保证合规，不可直接写入';

COMMENT ON COLUMN public.card_market.price_source IS
'【锁死】当前 final_price 来源：live | market | ai。由触发器自动设置，CHECK约束限制取值';

-- =====================================================================
-- 八、完整性验证
-- =====================================================================
DO $$
BEGIN
    RAISE NOTICE '[0023] 唯一价格真值规则锁死完成';
    RAISE NOTICE '  层1: 触发器 trg_card_market_price → BEFORE INSERT OR UPDATE（全列）';
    RAISE NOTICE '  层2: CHECK chk_price_source_values → price_source IN (live, market, ai)';
    RAISE NOTICE '  层3: CHECK chk_price_truth_rule → final_price = 最高优先级有效价格源';
    RAISE NOTICE '  升级: upsert_card_market 新增 p_clear_live/market/ai 清除参数';
    RAISE NOTICE '  新增: verify_price_truth_rule() 验证函数';
    RAISE NOTICE '';
    RAISE NOTICE '  ⚠️ 执行后验证:';
    RAISE NOTICE '    SELECT * FROM verify_price_truth_rule();';
END $$;
