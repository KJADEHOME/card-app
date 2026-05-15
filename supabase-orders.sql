-- 卡域 订单系统 数据库迁移脚本
-- 在原有supabase-setup.sql基础上新增订单相关表

-- ==========================================
-- 1. 订单表
-- ==========================================
CREATE TABLE IF NOT EXISTS public.orders (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    -- 基本信息
    order_no TEXT UNIQUE NOT NULL,           -- 订单编号，如 ORD20260407001
    listing_id UUID REFERENCES public.market_listings(id) ON DELETE CASCADE NOT NULL,
    buyer_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    seller_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    
    -- 卡牌信息快照（下单时复制，防止卖家修改）
    card_name TEXT NOT NULL,
    card_series TEXT NOT NULL,
    card_rarity TEXT NOT NULL,
    card_image_url TEXT,
    card_price DECIMAL(10,2) NOT NULL,        -- 下单时的价格
    
    -- 订单状态
    status TEXT NOT NULL DEFAULT 'pending_payment',
    -- 状态流转: pending_payment -> paid -> shipped -> completed
    --           pending_payment -> cancelled
    --           paid -> refunding -> refunded
    --           shipped -> refunding -> refunded
    
    -- 金额信息
    total_amount DECIMAL(10,2) NOT NULL,     -- 订单总额 = 卡牌价格 + 运费
    card_amount DECIMAL(10,2) NOT NULL,      -- 卡牌价格
    shipping_fee DECIMAL(10,2) NOT NULL DEFAULT 0, -- 运费
    platform_fee DECIMAL(10,2) NOT NULL DEFAULT 0, -- 平台手续费(3%)
    seller_amount DECIMAL(10,2) NOT NULL DEFAULT 0, -- 卖家实际收入
    
    -- 收货信息
    receiver_name TEXT,                       -- 收件人姓名
    receiver_phone TEXT,                      -- 收件人电话
    receiver_address TEXT,                    -- 收件地址
    
    -- 物流信息
    tracking_no TEXT,                         -- 快递单号
    shipping_company TEXT,                    -- 快递公司
    shipped_at TIMESTAMP WITH TIME ZONE,     -- 发货时间
    
    -- 支付信息
    payment_method TEXT,                      -- 支付方式: wechat, alipay, balance
    payment_at TIMESTAMP WITH TIME ZONE,     -- 支付时间
    payment_no TEXT,                          -- 支付流水号
    
    -- 完成信息
    completed_at TIMESTAMP WITH TIME ZONE,   -- 完成时间
    
    -- 取消/退款信息
    cancel_reason TEXT,                       -- 取消原因
    cancelled_at TIMESTAMP WITH TIME ZONE,   -- 取消时间
    
    -- 备注
    buyer_remark TEXT,                        -- 买家备注
    
    -- 时间戳
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==========================================
-- 2. 评价表
-- ==========================================
CREATE TABLE IF NOT EXISTS public.reviews (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE NOT NULL UNIQUE,
    reviewer_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,  -- 评价人
    target_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,     -- 被评价人
    rating INTEGER NOT NULL DEFAULT 5 CHECK (rating >= 1 AND rating <= 5),   -- 评分1-5
    content TEXT,                                                             -- 评价内容
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==========================================
-- 3. 用户钱包表（用于资金托管）
-- ==========================================
CREATE TABLE IF NOT EXISTS public.wallets (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL UNIQUE,
    balance DECIMAL(10,2) NOT NULL DEFAULT 0,         -- 可用余额
    frozen_balance DECIMAL(10,2) NOT NULL DEFAULT 0,  -- 冻结余额（交易中的钱）
    total_income DECIMAL(10,2) NOT NULL DEFAULT 0,    -- 累计收入
    total_expense DECIMAL(10,2) NOT NULL DEFAULT 0,   -- 累计支出
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==========================================
-- 4. 钱包流水表
-- ==========================================
CREATE TABLE IF NOT EXISTS public.wallet_transactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    wallet_id UUID REFERENCES public.wallets(id) ON DELETE CASCADE NOT NULL,
    order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
    type TEXT NOT NULL,  -- recharge(充值), payment(支付), income(收入), refund(退款), withdraw(提现), platform_fee(平台手续费)
    amount DECIMAL(10,2) NOT NULL,
    balance_after DECIMAL(10,2) NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==========================================
-- 5. 通知表
-- ==========================================
CREATE TABLE IF NOT EXISTS public.notifications (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'system',  -- system, order, message
    related_id TEXT,                       -- 关联的订单ID等
    is_read BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==========================================
-- 启用RLS
-- ==========================================
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- ==========================================
-- RLS 策略
-- ==========================================

-- orders: 买卖双方可读自己的订单，所有人可读active状态的listing
CREATE POLICY "Buyers can view their orders" ON public.orders
    FOR SELECT USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

CREATE POLICY "Anyone can create orders" ON public.orders
    FOR INSERT WITH CHECK (auth.uid() = buyer_id);

CREATE POLICY "Buyers can update their orders" ON public.orders
    FOR UPDATE USING (auth.uid() = buyer_id OR auth.uid() = seller_id);

-- reviews: 所有人可读，评价人可写
CREATE POLICY "Reviews are viewable by everyone" ON public.reviews
    FOR SELECT USING (true);

CREATE POLICY "Users can create reviews" ON public.reviews
    FOR INSERT WITH CHECK (auth.uid() = reviewer_id);

-- wallets: 仅本人可读可写
CREATE POLICY "Users can view own wallet" ON public.wallets
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own wallet" ON public.wallets
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own wallet" ON public.wallets
    FOR UPDATE USING (auth.uid() = user_id);

-- wallet_transactions: 仅本人可读
CREATE POLICY "Users can view own transactions" ON public.wallet_transactions
    FOR SELECT USING (
        EXISTS (SELECT 1 FROM public.wallets WHERE id = wallet_id AND user_id = auth.uid())
    );

CREATE POLICY "System can insert transactions" ON public.wallet_transactions
    FOR INSERT WITH CHECK (
        EXISTS (SELECT 1 FROM public.wallets WHERE id = wallet_id AND user_id = auth.uid())
    );

-- notifications: 仅本人可读可写
CREATE POLICY "Users can view own notifications" ON public.notifications
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "System can create notifications" ON public.notifications
    FOR INSERT WITH CHECK (true);

CREATE POLICY "Users can update own notifications" ON public.notifications
    FOR UPDATE USING (auth.uid() = user_id);

-- ==========================================
-- 触发器: 自动更新 updated_at
-- ==========================================
DROP TRIGGER IF EXISTS update_orders_updated_at ON public.orders;
CREATE TRIGGER update_orders_updated_at
    BEFORE UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_wallets_updated_at ON public.wallets;
CREATE TRIGGER update_wallets_updated_at
    BEFORE UPDATE ON public.wallets
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ==========================================
-- 索引（提升查询性能）
-- ==========================================
CREATE INDEX IF NOT EXISTS idx_orders_buyer ON public.orders(buyer_id);
CREATE INDEX IF NOT EXISTS idx_orders_seller ON public.orders(seller_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_listing ON public.orders(listing_id);
CREATE INDEX IF NOT EXISTS idx_orders_order_no ON public.orders(order_no);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_read ON public.notifications(user_id, is_read);
