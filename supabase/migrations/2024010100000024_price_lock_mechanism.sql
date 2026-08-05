-- =====================================================================
-- 0024: 价格锁定机制 (Price Lock Mechanism)
--
-- 目标：防止价格抖动导致资产乱跳，在真实用户+抖音流量+高频更新下保持稳定
--
-- 核心规则：
--   if price_locked = TRUE AND not expired:
--       final_price = locked_price    -- 冻结价格，不受底层价格波动影响
--   else:
--       final_price = unlocked_price  -- 恢复 live > market > ai 优先级
--
-- 新增列 (card_market):
--   price_locked     BOOLEAN      — 是否锁定
--   locked_price     NUMERIC      — 锁定价格
--   lock_timestamp   TIMESTAMPTZ  — 锁定时间
--   lock_expires_at  TIMESTAMPTZ  — 锁定过期时间（NULL=永不过期）
--   lock_reason      TEXT         — 锁定原因
--   unlocked_price   NUMERIC      — 未锁定时的"应有价格"（live>market>ai），用于波动检测
--
-- 新增表:
--   price_change_events — 记录 ≥5% 的 unlocked_price 变动，供自动锁定检测
--
-- 新增 RPC:
--   lock_card_price()              — 手动锁定
--   unlock_card_price()            — 手动解锁
--   check_and_auto_lock_prices()   — 自动检测波动并锁定/过期解锁
--   get_locked_cards()             — 查询锁定中的卡牌
--   get_price_change_events()      — 查询价格变动事件
--
-- 修改对象:
--   compute_card_market_price()    — 触发器函数增加锁定逻辑
--   chk_price_truth_rule           — CHECK 约束允许锁定价格
--   verify_price_truth_rule()      — 增加锁定合规检查
-- =====================================================================

-- =====================================================================
-- 一、card_market 新增列
-- =====================================================================
ALTER TABLE public.card_market ADD COLUMN IF NOT EXISTS price_locked BOOLEAN DEFAULT FALSE;
ALTER TABLE public.card_market ADD COLUMN IF NOT EXISTS locked_price NUMERIC(12,2);
ALTER TABLE public.card_market ADD COLUMN IF NOT EXISTS lock_timestamp TIMESTAMPTZ;
ALTER TABLE public.card_market ADD COLUMN IF NOT EXISTS lock_expires_at TIMESTAMPTZ;
ALTER TABLE public.card_market ADD COLUMN IF NOT EXISTS lock_reason TEXT;
ALTER TABLE public.card_market ADD COLUMN IF NOT EXISTS unlocked_price NUMERIC(12,2) DEFAULT 0;

COMMENT ON COLUMN public.card_market.price_locked IS '价格锁定开关。TRUE时final_price=locked_price，不受底层价格波动影响';
COMMENT ON COLUMN public.card_market.locked_price IS '锁定价格。锁定时final_price使用此值';
COMMENT ON COLUMN public.card_market.lock_timestamp IS '锁定生效时间';
COMMENT ON COLUMN public.card_market.lock_expires_at IS '锁定过期时间。NULL=永不过期。过期后触发器自动解锁';
COMMENT ON COLUMN public.card_market.lock_reason IS '锁定原因（manual/auto:xxx）';
COMMENT ON COLUMN public.card_market.unlocked_price IS '未锁定时的应有价格（live>market>ai），用于波动检测和锁定决策';

-- 初始化现有数据的 unlocked_price = final_price
UPDATE public.card_market
SET unlocked_price = final_price
WHERE unlocked_price = 0 AND final_price > 0;

-- =====================================================================
-- 二、锁一致性 CHECK 约束
-- =====================================================================
ALTER TABLE public.card_market DROP CONSTRAINT IF EXISTS chk_lock_consistency;
ALTER TABLE public.card_market ADD CONSTRAINT chk_lock_consistency CHECK (
    -- 未锁定：无要求
    price_locked = FALSE
    -- 已锁定：必须有 locked_price > 0 和 lock_timestamp
    OR (
        price_locked = TRUE
        AND locked_price IS NOT NULL
        AND locked_price > 0
        AND lock_timestamp IS NOT NULL
    )
);

COMMENT ON CONSTRAINT chk_lock_consistency ON public.card_market IS
'锁定一致性：price_locked=TRUE时必须有locked_price>0和lock_timestamp';

-- =====================================================================
-- 三、price_change_events 表 — 记录显著价格变动
-- =====================================================================
CREATE TABLE IF NOT EXISTS public.price_change_events (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    card_name TEXT NOT NULL,
    series TEXT DEFAULT '',
    rarity TEXT DEFAULT 'N',
    market TEXT DEFAULT 'CN',

    old_price NUMERIC(12,2) NOT NULL,
    new_price NUMERIC(12,2) NOT NULL,
    change_percent NUMERIC(8,2) NOT NULL,

    price_field TEXT NOT NULL DEFAULT 'unlocked',  -- 'unlocked' | 'live' | 'market' | 'ai'
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pce_card_time
    ON public.price_change_events(card_name, series, rarity, market, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_pce_cleanup
    ON public.price_change_events(recorded_at);

ALTER TABLE public.price_change_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can read price events" ON public.price_change_events;
CREATE POLICY "Anyone can read price events" ON public.price_change_events
    FOR SELECT USING (true);

COMMENT ON TABLE public.price_change_events IS '价格变动事件日志 — 记录≥5%的unlocked_price变动，供波动检测和自动锁定';

-- =====================================================================
-- 四、升级触发器函数 — 增加锁定逻辑
-- =====================================================================
CREATE OR REPLACE FUNCTION public.compute_card_market_price()
RETURNS TRIGGER AS $$
DECLARE
    v_computed_price NUMERIC(12,2);
    v_computed_source TEXT;
BEGIN
    -- ================================================================
    -- Step 1: 始终计算 unlocked_price（live > market > ai 优先级）
    -- 即使锁定时也计算，用于波动检测和锁定决策
    -- ================================================================
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
        v_computed_price := 0;
        v_computed_source := 'ai';
    END IF;

    NEW.unlocked_price := v_computed_price;
    NEW.price_source := v_computed_source;  -- price_source 始终反映底层来源

    -- ================================================================
    -- Step 2: 根据锁定状态决定 final_price
    -- ================================================================

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
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.compute_card_market_price() IS
'【0024升级】触发器函数：1)计算unlocked_price(live>market>ai) 2)锁定时final_price=locked_price 3)过期自动解锁 4)未锁定final_price=unlocked_price';

-- =====================================================================
-- 五、新增 AFTER 触发器 — 记录显著价格变动到 price_change_events
--    只在 unlocked_price 变动 ≥5% 时写入，避免每次更新都写日志
-- =====================================================================
CREATE OR REPLACE FUNCTION public.log_significant_price_changes()
RETURNS TRIGGER AS $$
DECLARE
    v_old_unlocked NUMERIC;
    v_new_unlocked NUMERIC;
    v_change_pct NUMERIC;
BEGIN
    v_old_unlocked := COALESCE(OLD.unlocked_price, 0);
    v_new_unlocked := COALESCE(NEW.unlocked_price, 0);

    -- 只在 unlocked_price 有实质变化时记录
    IF v_old_unlocked > 0
       AND v_new_unlocked > 0
       AND v_new_unlocked <> v_old_unlocked THEN

        v_change_pct := ABS((v_new_unlocked - v_old_unlocked) / v_old_unlocked * 100);

        IF v_change_pct >= 5.0 THEN
            INSERT INTO public.price_change_events (
                card_name, series, rarity, market,
                old_price, new_price, change_percent, price_field
            ) VALUES (
                NEW.card_name, NEW.series, NEW.rarity, NEW.market,
                v_old_unlocked, v_new_unlocked, ROUND(v_change_pct, 2), 'unlocked'
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_log_price_changes ON public.card_market;
CREATE TRIGGER trg_log_price_changes
    AFTER UPDATE OF live_price, market_price, ai_estimate_price
    ON public.card_market
    FOR EACH ROW
    EXECUTE FUNCTION public.log_significant_price_changes();

COMMENT ON FUNCTION public.log_significant_price_changes() IS
'触发器函数：unlocked_price变动≥5%时写入price_change_events，用于波动检测';

-- =====================================================================
-- 六、升级 CHECK 约束 — 允许锁定价格
-- =====================================================================

-- 6.1 重建 chk_price_truth_rule（允许锁定时 final_price = locked_price）
ALTER TABLE public.card_market DROP CONSTRAINT IF EXISTS chk_price_truth_rule;

ALTER TABLE public.card_market ADD CONSTRAINT chk_price_truth_rule CHECK (
    -- Case 0: 价格锁定 → final_price = locked_price
    (
        price_locked = TRUE
        AND COALESCE(locked_price, 0) > 0
        AND final_price = locked_price
        AND price_source IN ('live', 'market', 'ai')
    )
    -- Case 1-4: 未锁定 → 标准真值规则 (final_price = unlocked_price = 最高优先级有效价格源)
    OR (
        price_locked = FALSE
        AND (
            -- live 有效
            (
                COALESCE(live_price, 0) > 0
                AND final_price = live_price
                AND final_price = unlocked_price
                AND price_source = 'live'
            )
            -- market 有效 (live 无效)
            OR (
                COALESCE(live_price, 0) <= 0
                AND COALESCE(market_price, 0) > 0
                AND final_price = market_price
                AND final_price = unlocked_price
                AND price_source = 'market'
            )
            -- ai 有效 (live+market 无效)
            OR (
                COALESCE(live_price, 0) <= 0
                AND COALESCE(market_price, 0) <= 0
                AND COALESCE(ai_estimate_price, 0) > 0
                AND final_price = ai_estimate_price
                AND final_price = unlocked_price
                AND price_source = 'ai'
            )
            -- 全部无效
            OR (
                COALESCE(live_price, 0) <= 0
                AND COALESCE(market_price, 0) <= 0
                AND COALESCE(ai_estimate_price, 0) <= 0
                AND final_price = 0
                AND final_price = unlocked_price
                AND price_source = 'ai'
            )
        )
    )
);

COMMENT ON CONSTRAINT chk_price_truth_rule ON public.card_market IS
'【0024升级】final_price规则：锁定时=locked_price；未锁定时=最高优先级有效价格源(live>market>ai)=unlocked_price';

-- 6.2 chk_price_source_values 保持不变（live/market/ai）

-- =====================================================================
-- 七、RPC: lock_card_price — 手动锁定
-- =====================================================================
CREATE OR REPLACE FUNCTION public.lock_card_price(
    p_card_name TEXT,
    p_series TEXT DEFAULT '',
    p_rarity TEXT DEFAULT 'N',
    p_market TEXT DEFAULT 'CN',
    p_locked_price NUMERIC DEFAULT NULL,
    p_reason TEXT DEFAULT 'manual',
    p_duration_hours INTEGER DEFAULT NULL  -- NULL = 永不过期
) RETURNS TABLE(
    out_name TEXT,
    out_locked_price NUMERIC,
    out_final_price NUMERIC,
    out_price_source TEXT,
    out_locked BOOLEAN
) AS $$
DECLARE
    v_name ALIAS FOR p_card_name;
BEGIN
    IF p_locked_price IS NULL OR p_locked_price <= 0 THEN
        RAISE EXCEPTION 'locked_price must be positive, got %', p_locked_price;
    END IF;

    UPDATE public.card_market
    SET
        price_locked = TRUE,
        locked_price = p_locked_price,
        lock_timestamp = NOW(),
        lock_expires_at = CASE
            WHEN p_duration_hours IS NOT NULL THEN NOW() + (p_duration_hours || ' hours')::INTERVAL
            ELSE NULL  -- 永不过期
        END,
        lock_reason = p_reason
        -- final_price 由 BEFORE 触发器自动设为 locked_price
    WHERE card_name = v_name
      AND series = p_series
      AND rarity = p_rarity
      AND market = p_market;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Card not found: % / % / % / %', v_name, p_series, p_rarity, p_market;
    END IF;

    RETURN QUERY
    SELECT
        cm.card_name,
        cm.locked_price,
        cm.final_price,
        cm.price_source,
        cm.price_locked
    FROM public.card_market cm
    WHERE cm.card_name = v_name
      AND cm.series = p_series
      AND cm.rarity = p_rarity
      AND cm.market = p_market;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.lock_card_price IS
'手动锁定卡牌价格。锁定后final_price=locked_price，不受底层价格波动影响。p_duration_hours=NULL表示永不过期';

-- =====================================================================
-- 八、RPC: unlock_card_price — 手动解锁
-- =====================================================================
CREATE OR REPLACE FUNCTION public.unlock_card_price(
    p_card_name TEXT,
    p_series TEXT DEFAULT '',
    p_rarity TEXT DEFAULT 'N',
    p_market TEXT DEFAULT 'CN'
) RETURNS TABLE(
    out_name TEXT,
    out_final_price NUMERIC,
    out_price_source TEXT,
    out_locked BOOLEAN
) AS $$
DECLARE
    v_name ALIAS FOR p_card_name;
BEGIN
    UPDATE public.card_market
    SET
        price_locked = FALSE,
        locked_price = NULL,
        lock_timestamp = NULL,
        lock_expires_at = NULL,
        lock_reason = NULL
        -- final_price 由 BEFORE 触发器自动恢复为 unlocked_price
    WHERE card_name = v_name
      AND series = p_series
      AND rarity = p_rarity
      AND market = p_market;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Card not found: % / % / % / %', v_name, p_series, p_rarity, p_market;
    END IF;

    RETURN QUERY
    SELECT
        cm.card_name,
        cm.final_price,
        cm.price_source,
        cm.price_locked
    FROM public.card_market cm
    WHERE cm.card_name = v_name
      AND cm.series = p_series
      AND cm.rarity = p_rarity
      AND cm.market = p_market;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.unlock_card_price IS
'手动解锁卡牌价格。解锁后final_price恢复为unlocked_price(live>market>ai)';

-- =====================================================================
-- 九、RPC: check_and_auto_lock_prices — 自动检测波动并锁定
--
-- 流程：
--   1. 清理过期事件（>24小时）
--   2. 自动解锁过期锁定
--   3. 检测窗口内高波动卡牌 → 自动锁定
--
-- 自动锁定条件：
--   - 窗口内变动事件数 >= p_min_events
--   - 最大变动幅度 >= p_threshold_pct
--   - 当前未锁定
--   - 锁定价格 = 窗口内最早事件的 old_price（波动前的稳定价格）
--   - 锁定时长 = p_lock_duration_hours
-- =====================================================================
CREATE OR REPLACE FUNCTION public.check_and_auto_lock_prices(
    p_market TEXT DEFAULT 'CN',
    p_threshold_pct NUMERIC DEFAULT 10.0,
    p_window_hours INTEGER DEFAULT 1,
    p_min_events INTEGER DEFAULT 2,
    p_lock_duration_hours INTEGER DEFAULT 2
) RETURNS TABLE(
    expired_unlocks INTEGER,
    auto_locks INTEGER,
    locked_cards JSON
) AS $$
DECLARE
    v_expired INTEGER := 0;
    v_locked INTEGER := 0;
    v_locked_list JSON;
    v_window_interval TEXT;
BEGIN
    v_window_interval := p_window_hours || ' hours';

    -- Step 1: 清理过期事件（保留24小时）
    DELETE FROM public.price_change_events
    WHERE recorded_at < NOW() - INTERVAL '24 hours';

    -- Step 2: 自动解锁过期锁定
    -- 触发器的 Case A 会在下次 UPDATE 时自动解锁
    -- 但这里主动触发一次 UPDATE 以立即生效
    UPDATE public.card_market
    SET updated_at = NOW()  -- 触发 BEFORE 触发器，检测过期并自动解锁
    WHERE price_locked = TRUE
      AND lock_expires_at IS NOT NULL
      AND lock_expires_at < NOW()
      AND market = p_market;

    GET DIAGNOSTICS v_expired = ROW_COUNT;

    -- Step 3: 检测高波动卡牌并自动锁定
    WITH event_stats AS (
        SELECT
            e.card_name,
            e.series,
            e.rarity,
            e.market,
            COUNT(*) AS evt_count,
            MAX(e.change_percent) AS max_change,
            -- 窗口内最早事件的 old_price = 波动前的稳定价格
            (array_agg(e.old_price ORDER BY e.recorded_at ASC))[1] AS stable_price
        FROM public.price_change_events e
        WHERE e.recorded_at >= NOW() - v_window_interval::INTERVAL
          AND e.market = p_market
        GROUP BY e.card_name, e.series, e.rarity, e.market
        HAVING COUNT(*) >= p_min_events
           AND MAX(e.change_percent) >= p_threshold_pct
    )
    UPDATE public.card_market cm
    SET
        price_locked = TRUE,
        locked_price = es.stable_price,
        lock_timestamp = NOW(),
        lock_expires_at = NOW() + (p_lock_duration_hours || ' hours')::INTERVAL,
        lock_reason = 'auto: ' || es.evt_count || ' events, max ' || es.max_change || '% in ' || p_window_hours || 'h'
    FROM event_stats es
    WHERE cm.card_name = es.card_name
      AND cm.series = es.series
      AND cm.rarity = es.rarity
      AND cm.market = es.market
      AND cm.price_locked = FALSE;  -- 不重复锁定

    GET DIAGNOSTICS v_locked = ROW_COUNT;

    -- 收集锁定卡牌列表
    SELECT COALESCE(json_agg(json_build_object(
        'card_name', t.card_name,
        'series', t.series,
        'rarity', t.rarity,
        'locked_price', t.locked_price,
        'lock_reason', t.lock_reason,
        'lock_expires_at', t.lock_expires_at
    )), '[]'::json)
    INTO v_locked_list
    FROM (
        SELECT card_name, series, rarity, locked_price, lock_reason, lock_expires_at
        FROM public.card_market
        WHERE price_locked = TRUE
          AND lock_reason LIKE 'auto:%'
          AND lock_timestamp >= NOW() - INTERVAL '5 minutes'
          AND market = p_market
    ) t;

    expired_unlocks := v_expired;
    auto_locks := v_locked;
    locked_cards := v_locked_list;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.check_and_auto_lock_prices IS
'自动检测价格波动并锁定：1)清理过期事件 2)解锁过期锁定 3)检测高波动卡牌并自动锁定。由Edge Function定期调用';

-- =====================================================================
-- 十、RPC: get_locked_cards — 查询锁定中的卡牌
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_locked_cards(
    p_market TEXT DEFAULT 'CN'
) RETURNS TABLE(
    card_name TEXT,
    series TEXT,
    rarity TEXT,
    locked_price NUMERIC,
    unlocked_price NUMERIC,
    final_price NUMERIC,
    price_source TEXT,
    lock_reason TEXT,
    lock_timestamp TIMESTAMPTZ,
    lock_expires_at TIMESTAMPTZ,
    is_expired BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        cm.card_name,
        cm.series,
        cm.rarity,
        cm.locked_price,
        cm.unlocked_price,
        cm.final_price,
        cm.price_source,
        cm.lock_reason,
        cm.lock_timestamp,
        cm.lock_expires_at,
        CASE
            WHEN cm.lock_expires_at IS NOT NULL AND cm.lock_expires_at < NOW() THEN TRUE
            ELSE FALSE
        END
    FROM public.card_market cm
    WHERE cm.price_locked = TRUE
      AND cm.market = p_market
    ORDER BY cm.lock_timestamp DESC;

    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_locked_cards IS '查询当前锁定中的卡牌列表';

-- =====================================================================
-- 十一、RPC: get_price_change_events — 查询价格变动事件
-- =====================================================================
CREATE OR REPLACE FUNCTION public.get_price_change_events(
    p_card_name TEXT DEFAULT NULL,
    p_series TEXT DEFAULT '',
    p_rarity TEXT DEFAULT 'N',
    p_market TEXT DEFAULT 'CN',
    p_hours INTEGER DEFAULT 1
) RETURNS TABLE(
    card_name TEXT,
    series TEXT,
    rarity TEXT,
    market TEXT,
    old_price NUMERIC,
    new_price NUMERIC,
    change_percent NUMERIC,
    price_field TEXT,
    recorded_at TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        e.card_name,
        e.series,
        e.rarity,
        e.market,
        e.old_price,
        e.new_price,
        e.change_percent,
        e.price_field,
        e.recorded_at
    FROM public.price_change_events e
    WHERE e.recorded_at >= NOW() - (p_hours || ' hours')::INTERVAL
      AND (p_card_name IS NULL OR e.card_name = p_card_name)
      AND e.series = p_series
      AND e.rarity = p_rarity
      AND e.market = p_market
    ORDER BY e.recorded_at DESC;

    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_price_change_events IS
'查询价格变动事件。p_card_name=NULL查询全部，p_hours指定时间窗口';

-- =====================================================================
-- 十二、升级 verify_price_truth_rule — 增加锁定合规检查
-- =====================================================================
-- 先 DROP 旧函数（返回类型不同，CREATE OR REPLACE 会失败）
DROP FUNCTION IF EXISTS public.verify_price_truth_rule();

CREATE OR REPLACE FUNCTION public.verify_price_truth_rule()
RETURNS TABLE(
    total_cards INTEGER,
    compliant INTEGER,
    violations INTEGER,
    locked_count INTEGER,
    unlocked_count INTEGER,
    violation_details JSON
) AS $$
DECLARE
    v_total INTEGER;
    v_compliant INTEGER;
    v_violations INTEGER;
    v_locked INTEGER;
    v_unlocked INTEGER;
    v_details JSON;
BEGIN
    SELECT
        COUNT(*),
        COUNT(*) FILTER (
            WHERE
                -- Case 0: 锁定 → final_price = locked_price
                (
                    price_locked = TRUE
                    AND COALESCE(locked_price, 0) > 0
                    AND final_price = locked_price
                    AND price_source IN ('live', 'market', 'ai')
                )
                -- Case 1: 未锁定, live 有效
                OR (
                    price_locked = FALSE
                    AND COALESCE(live_price, 0) > 0
                    AND final_price = live_price
                    AND final_price = unlocked_price
                    AND price_source = 'live'
                )
                -- Case 2: 未锁定, market 有效
                OR (
                    price_locked = FALSE
                    AND COALESCE(live_price, 0) <= 0
                    AND COALESCE(market_price, 0) > 0
                    AND final_price = market_price
                    AND final_price = unlocked_price
                    AND price_source = 'market'
                )
                -- Case 3: 未锁定, ai 有效
                OR (
                    price_locked = FALSE
                    AND COALESCE(live_price, 0) <= 0
                    AND COALESCE(market_price, 0) <= 0
                    AND COALESCE(ai_estimate_price, 0) > 0
                    AND final_price = ai_estimate_price
                    AND final_price = unlocked_price
                    AND price_source = 'ai'
                )
                -- Case 4: 未锁定, 全部无效
                OR (
                    price_locked = FALSE
                    AND COALESCE(live_price, 0) <= 0
                    AND COALESCE(market_price, 0) <= 0
                    AND COALESCE(ai_estimate_price, 0) <= 0
                    AND final_price = 0
                    AND final_price = unlocked_price
                    AND price_source = 'ai'
                )
        ),
        COUNT(*) FILTER (WHERE price_locked = TRUE),
        COUNT(*) FILTER (WHERE price_locked = FALSE)
    INTO v_total, v_compliant, v_locked, v_unlocked
    FROM public.card_market;

    v_violations := v_total - v_compliant;

    IF v_violations > 0 THEN
        SELECT COALESCE(json_agg(row_to_json(t)), '[]'::json)
        INTO v_details
        FROM (
            SELECT
                card_name, series, rarity, market,
                price_locked, locked_price, unlocked_price,
                live_price, market_price, ai_estimate_price,
                final_price, price_source,
                lock_expires_at
            FROM public.card_market
            WHERE NOT (
                -- Case 0: 锁定
                (price_locked = TRUE AND COALESCE(locked_price, 0) > 0 AND final_price = locked_price AND price_source IN ('live', 'market', 'ai'))
                -- Case 1-4: 未锁定
                OR (price_locked = FALSE AND COALESCE(live_price, 0) > 0 AND final_price = live_price AND final_price = unlocked_price AND price_source = 'live')
                OR (price_locked = FALSE AND COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) > 0 AND final_price = market_price AND final_price = unlocked_price AND price_source = 'market')
                OR (price_locked = FALSE AND COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) <= 0 AND COALESCE(ai_estimate_price, 0) > 0 AND final_price = ai_estimate_price AND final_price = unlocked_price AND price_source = 'ai')
                OR (price_locked = FALSE AND COALESCE(live_price, 0) <= 0 AND COALESCE(market_price, 0) <= 0 AND COALESCE(ai_estimate_price, 0) <= 0 AND final_price = 0 AND final_price = unlocked_price AND price_source = 'ai')
            )
        ) t;
    ELSE
        v_details := '[]'::json;
    END IF;

    total_cards := v_total;
    compliant := v_compliant;
    violations := v_violations;
    locked_count := v_locked;
    unlocked_count := v_unlocked;
    violation_details := v_details;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.verify_price_truth_rule() IS
'【0024升级】验证价格真值规则：检查锁定和未锁定两种状态的合规性，返回违规详情';

-- =====================================================================
-- 十三、更新 upsert_card_market — 确保 unlocked_price 同步
--    upsert 不直接管理锁定，锁定通过 lock/unlock_card_price RPC 管理
--    但需要确保 upsert 更新价格后 unlocked_price 被触发器正确计算
-- =====================================================================
-- 触发器会在 INSERT/UPDATE 时自动计算 unlocked_price，无需修改 upsert_card_market
-- 但需要在 ON CONFLICT DO UPDATE 中不触碰锁定相关字段

-- 确认 upsert_card_market 的 ON CONFLICT 不覆盖锁定字段
-- 当前 upsert_card_market 只更新 live_price/market_price/ai_estimate_price 等
-- 不涉及 price_locked/locked_price 等字段 → 安全

-- =====================================================================
-- 十四、索引优化
-- =====================================================================
CREATE INDEX IF NOT EXISTS idx_card_market_locked
    ON public.card_market(price_locked, lock_expires_at)
    WHERE price_locked = TRUE;

CREATE INDEX IF NOT EXISTS idx_card_market_unlocked
    ON public.card_market(unlocked_price DESC)
    WHERE price_locked = FALSE;

-- =====================================================================
-- 十五、表注释更新
-- =====================================================================
COMMENT ON TABLE public.card_market IS
'卡牌多源价格聚合表 —— 【0024】支持价格锁定(Price Lock)。锁定时final_price=locked_price，防止抖动。未锁定时final_price=unlocked_price(live>market>ai)';

-- =====================================================================
-- 十六、完整性验证
-- =====================================================================
DO $$
BEGIN
    RAISE NOTICE '[0024] 价格锁定机制 (Price Lock) 迁移完成';
    RAISE NOTICE '  新增列: price_locked, locked_price, lock_timestamp, lock_expires_at, lock_reason, unlocked_price';
    RAISE NOTICE '  新增表: price_change_events (显著价格变动日志, >= 5pct)';
    RAISE NOTICE '  升级触发器: compute_card_market_price() (锁定逻辑)';
    RAISE NOTICE '  新增触发器: trg_log_price_changes (AFTER UPDATE OF unlocked_price)';
    RAISE NOTICE '  升级CHECK: chk_price_truth_rule (允许锁定) + chk_lock_consistency (新增)';
    RAISE NOTICE '  新增RPC:';
    RAISE NOTICE '    lock_card_price()              — 手动锁定';
    RAISE NOTICE '    unlock_card_price()            — 手动解锁';
    RAISE NOTICE '    check_and_auto_lock_prices()   — 自动检测+锁定+过期解锁';
    RAISE NOTICE '    get_locked_cards()             — 查询锁定卡牌';
    RAISE NOTICE '    get_price_change_events()      — 查询变动事件';
    RAISE NOTICE '  升级RPC: verify_price_truth_rule() (增加锁定检查)';
    RAISE NOTICE '';
    RAISE NOTICE '  ⚠️ 执行后验证:';
    RAISE NOTICE '    SELECT * FROM verify_price_truth_rule();';
    RAISE NOTICE '    SELECT * FROM lock_card_price(''Charizard'', ''Pokemon'', ''N'', ''CN'', 3000, ''test'', 1);';
    RAISE NOTICE '    SELECT * FROM get_locked_cards(''CN'');';
    RAISE NOTICE '    SELECT * FROM unlock_card_price(''Charizard'', ''Pokemon'', ''N'', ''CN'');';
END $$;
