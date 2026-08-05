-- ============================================
-- 卡域 - 卡牌寄售交易系统（盈利核心）
-- ============================================

-- 1. 寄售表（卖家发布卡牌寄售）
CREATE TABLE IF NOT EXISTS public.consignments (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    seller_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    
    -- 卡牌信息
    card_name TEXT NOT NULL,
    card_name_en TEXT,
    card_image TEXT,
    series TEXT,
    rarity TEXT,
    card_category TEXT DEFAULT 'pokemon',
    condition TEXT DEFAULT 'NM' CHECK (condition IN ('M','NM','LP','MP','HP','D')),
    
    -- 定价
    asking_price NUMERIC(12,2) NOT NULL,
    currency TEXT DEFAULT 'CNY',
    
    -- 手续费与结算
    platform_fee_pct NUMERIC(5,2) DEFAULT 8.00,      -- 平台抽成比例（%）
    platform_fee NUMERIC(12,2) DEFAULT 0,             -- 平台手续费金额
    seller_earnings NUMERIC(12,2) DEFAULT 0,          -- 卖家实际到手
    
    -- 物流
    shipping_fee NUMERIC(12,2) DEFAULT 0,             -- 运费
    shipping_from TEXT,                                -- 发货地
    shipping_method TEXT DEFAULT 'express',            -- 快递/面交/邮寄
    
    -- 状态机
    status TEXT DEFAULT 'active' 
        CHECK (status IN ('draft','active','reserved','sold','shipped','completed','cancelled','disputed')),
    
    -- 描述与标签
    description TEXT,
    tags TEXT[],
    
    -- 统计
    view_count INTEGER DEFAULT 0,
    wishlist_count INTEGER DEFAULT 0,
    
    -- 时间
    listed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    sold_at TIMESTAMP WITH TIME ZONE,
    expires_at TIMESTAMP WITH TIME ZONE DEFAULT (NOW() + INTERVAL '30 days'),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_consignments_seller ON public.consignments(seller_id);
CREATE INDEX IF NOT EXISTS idx_consignments_status ON public.consignments(status);
CREATE INDEX IF NOT EXISTS idx_consignments_category ON public.consignments(card_category);
CREATE INDEX IF NOT EXISTS idx_consignments_price ON public.consignments(asking_price);
CREATE INDEX IF NOT EXISTS idx_consignments_created ON public.consignments(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_consignments_series ON public.consignments(series);

-- 2. 订单表（买家下单）
CREATE TABLE IF NOT EXISTS public.orders (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_no TEXT UNIQUE NOT NULL,                    -- 订单编号 e.g. CR20260601001
    
    buyer_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    seller_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    consignment_id UUID REFERENCES public.consignments(id) ON DELETE SET NULL,
    
    -- 金额
    item_price NUMERIC(12,2) NOT NULL,                -- 卡牌售价
    shipping_fee NUMERIC(12,2) DEFAULT 0,             -- 运费
    platform_fee NUMERIC(12,2) DEFAULT 0,             -- 平台手续费
    total_amount NUMERIC(12,2) NOT NULL,              -- 买家支付总额
    seller_earnings NUMERIC(12,2) DEFAULT 0,          -- 卖家应得
    
    currency TEXT DEFAULT 'CNY',
    
    -- 状态
    status TEXT DEFAULT 'pending' 
        CHECK (status IN ('pending','paid','shipped','delivered','completed','cancelled','refunded','disputed')),
    
    -- 物流
    tracking_no TEXT,
    shipping_carrier TEXT,
    shipped_at TIMESTAMP WITH TIME ZONE,
    delivered_at TIMESTAMP WITH TIME ZONE,
    
    -- 地址
    buyer_address JSONB,
    
    -- 时间
    paid_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_orders_buyer ON public.orders(buyer_id);
CREATE INDEX IF NOT EXISTS idx_orders_seller ON public.orders(seller_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_order_no ON public.orders(order_no);
CREATE INDEX IF NOT EXISTS idx_orders_created ON public.orders(created_at DESC);

-- 3. 资金托管表（交易担保）
CREATE TABLE IF NOT EXISTS public.escrow_transactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE NOT NULL,
    
    -- 资金流向
    from_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    to_user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    
    amount NUMERIC(12,2) NOT NULL,
    currency TEXT DEFAULT 'CNY',
    
    -- 类型
    type TEXT NOT NULL CHECK (type IN ('deposit','release','refund','fee','payout')),
    
    -- 状态
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending','completed','failed','cancelled')),
    
    -- 支付渠道
    payment_method TEXT,                               -- alipay/wechat/stripe/paypal
    payment_tx_id TEXT,                                -- 第三方交易号
    
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE
);

CREATE INDEX IF NOT EXISTS idx_escrow_order ON public.escrow_transactions(order_id);
CREATE INDEX IF NOT EXISTS idx_escrow_from ON public.escrow_transactions(from_user_id);
CREATE INDEX IF NOT EXISTS idx_escrow_to ON public.escrow_transactions(to_user_id);

-- 4. 平台佣金记录表
CREATE TABLE IF NOT EXISTS public.platform_fees (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
    consignment_id UUID REFERENCES public.consignments(id) ON DELETE SET NULL,
    
    fee_type TEXT NOT NULL CHECK (fee_type IN ('transaction','listing','promotion','withdrawal')),
    fee_amount NUMERIC(12,2) NOT NULL,
    fee_pct NUMERIC(5,2),                              -- 费率（%）
    
    currency TEXT DEFAULT 'CNY',
    description TEXT,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fees_order ON public.platform_fees(order_id);
CREATE INDEX IF NOT EXISTS idx_fees_type ON public.platform_fees(fee_type);

-- 5. 用户钱包表（余额系统）
CREATE TABLE IF NOT EXISTS public.wallets (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE NOT NULL,
    
    balance NUMERIC(14,2) DEFAULT 0,                   -- 可用余额
    frozen_balance NUMERIC(14,2) DEFAULT 0,            -- 冻结金额
    total_earned NUMERIC(14,2) DEFAULT 0,              -- 累计收入
    total_spent NUMERIC(14,2) DEFAULT 0,               -- 累计支出
    
    currency TEXT DEFAULT 'CNY',
    
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallets_user ON public.wallets(user_id);

-- 6. 钱包流水表
CREATE TABLE IF NOT EXISTS public.wallet_transactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    wallet_id UUID REFERENCES public.wallets(id) ON DELETE CASCADE NOT NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    
    amount NUMERIC(14,2) NOT NULL,                     -- 正数=收入，负数=支出
    balance_after NUMERIC(14,2) NOT NULL,              -- 变动后余额
    
    type TEXT NOT NULL CHECK (type IN ('deposit','withdrawal','sale','purchase','refund','fee','reward')),
    
    reference_id UUID,                                 -- 关联订单/寄售ID
    reference_type TEXT,                               -- order/consignment
    
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallet_tx_wallet ON public.wallet_transactions(wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_user ON public.wallet_transactions(user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_tx_created ON public.wallet_transactions(created_at DESC);

-- 触发器：自动计算手续费和卖家收益
CREATE OR REPLACE FUNCTION calculate_consignment_fees()
RETURNS TRIGGER AS $$
BEGIN
    NEW.platform_fee := ROUND(NEW.asking_price * NEW.platform_fee_pct / 100, 2);
    NEW.seller_earnings := NEW.asking_price - NEW.platform_fee;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_calculate_fees ON public.consignments;
CREATE TRIGGER trg_calculate_fees
    BEFORE INSERT OR UPDATE OF asking_price, platform_fee_pct ON public.consignments
    FOR EACH ROW EXECUTE FUNCTION calculate_consignment_fees();

-- 触发器：订单金额计算
CREATE OR REPLACE FUNCTION calculate_order_amounts()
RETURNS TRIGGER AS $$
DECLARE
    v_consign public.consignments%ROWTYPE;
BEGIN
    SELECT * INTO v_consign FROM public.consignments WHERE id = NEW.consignment_id;
    IF FOUND THEN
        NEW.item_price := v_consign.asking_price;
        NEW.shipping_fee := v_consign.shipping_fee;
        NEW.platform_fee := v_consign.platform_fee;
        NEW.seller_earnings := v_consign.seller_earnings;
        NEW.total_amount := v_consign.asking_price + COALESCE(v_consign.shipping_fee, 0);
        NEW.seller_id := v_consign.seller_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_calculate_order ON public.orders;
CREATE TRIGGER trg_calculate_order
    BEFORE INSERT ON public.orders
    FOR EACH ROW EXECUTE FUNCTION calculate_order_amounts();

-- 触发器：创建用户钱包
CREATE OR REPLACE FUNCTION create_user_wallet()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.wallets (user_id) VALUES (NEW.id)
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_create_wallet ON auth.users;
CREATE TRIGGER trg_create_wallet
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION create_user_wallet();

-- 更新时间触发器
CREATE OR REPLACE TRIGGER update_consignments_updated_at
    BEFORE UPDATE ON public.consignments
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE OR REPLACE TRIGGER update_orders_updated_at
    BEFORE UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE OR REPLACE TRIGGER update_wallets_updated_at
    BEFORE UPDATE ON public.wallets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- RLS 策略
ALTER TABLE public.consignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.escrow_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_fees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;

-- 寄售：所有人可查看活跃的，卖家管理自己的
DROP POLICY IF EXISTS "Anyone can view active consignments" ON public.consignments;
CREATE POLICY "Anyone can view active consignments" ON public.consignments
    FOR SELECT USING (status = 'active');

DROP POLICY IF EXISTS "Sellers manage own consignments" ON public.consignments;
CREATE POLICY "Sellers manage own consignments" ON public.consignments
    FOR ALL USING (auth.uid() = seller_id);

-- 订单：买卖双方可见
DROP POLICY IF EXISTS "Buyers and sellers view orders" ON public.orders;
CREATE POLICY "Buyers and sellers view orders" ON public.orders
    FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

DROP POLICY IF EXISTS "Buyers can create orders" ON public.orders;
CREATE POLICY "Buyers can create orders" ON public.orders
    FOR INSERT WITH CHECK (auth.uid() = buyer_id);

DROP POLICY IF EXISTS "Buyers and sellers update orders" ON public.orders;
CREATE POLICY "Buyers and sellers update orders" ON public.orders
    FOR UPDATE USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

-- 钱包：仅自己
DROP POLICY IF EXISTS "Users own wallet" ON public.wallets;
CREATE POLICY "Users own wallet" ON public.wallets
    FOR ALL USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users view own transactions" ON public.wallet_transactions;
CREATE POLICY "Users view own transactions" ON public.wallet_transactions
    FOR SELECT USING (auth.uid() = user_id);

-- 插入平台默认手续费配置（用于前端显示）
CREATE TABLE IF NOT EXISTS public.platform_config (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    key TEXT UNIQUE NOT NULL,
    value TEXT NOT NULL,
    description TEXT,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

INSERT INTO public.platform_config (key, value, description) VALUES
    ('fee_transaction_pct', '8', '交易手续费比例（%）'),
    ('fee_listing', '0', '上架费（元）'),
    ('fee_withdrawal_pct', '1', '提现手续费比例（%）'),
    ('min_withdrawal', '100', '最小提现金额（元）'),
    ('escrow_hold_days', '7', '确认收货后资金冻结天数'),
    ('shipping_default', '12', '默认运费（元）')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.platform_config ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can view config" ON public.platform_config FOR SELECT USING (true);
