-- ============================================
-- 卡域 完整数据库初始化脚本（安全版）
-- 使用 DO 块包裹，忽略已存在的策略和触发器错误
-- ============================================

-- 0. 时间戳更新函数
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ==========================================
-- 创建表（IF NOT EXISTS，安全重复执行）
-- ==========================================

CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    avatar_url TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.cards (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    name TEXT NOT NULL,
    series TEXT NOT NULL DEFAULT '游戏王',
    rarity TEXT NOT NULL DEFAULT 'N',
    price DECIMAL(10,2) DEFAULT 0,
    description TEXT,
    image_url TEXT,
    is_for_sale BOOLEAN DEFAULT false,
    favorite BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.messages (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    sender_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    receiver_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    card_id UUID REFERENCES public.cards(id) ON DELETE SET NULL,
    content TEXT NOT NULL,
    is_read BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.market_listings (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    card_id UUID REFERENCES public.cards(id) ON DELETE CASCADE NOT NULL,
    seller_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    status TEXT DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.favorites (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    card_id UUID REFERENCES public.market_listings(id) ON DELETE CASCADE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(user_id, card_id)
);

CREATE TABLE IF NOT EXISTS public.orders (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_no TEXT UNIQUE NOT NULL,
    listing_id UUID REFERENCES public.market_listings(id) ON DELETE CASCADE NOT NULL,
    buyer_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    seller_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    card_name TEXT NOT NULL,
    card_series TEXT NOT NULL,
    card_rarity TEXT NOT NULL,
    card_image_url TEXT,
    card_price DECIMAL(10,2) NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending_payment',
    total_amount DECIMAL(10,2) NOT NULL,
    card_amount DECIMAL(10,2) NOT NULL,
    shipping_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
    platform_fee DECIMAL(10,2) NOT NULL DEFAULT 0,
    seller_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
    receiver_name TEXT,
    receiver_phone TEXT,
    receiver_address TEXT,
    tracking_no TEXT,
    shipping_company TEXT,
    shipped_at TIMESTAMP WITH TIME ZONE,
    payment_method TEXT,
    payment_at TIMESTAMP WITH TIME ZONE,
    payment_no TEXT,
    completed_at TIMESTAMP WITH TIME ZONE,
    cancel_reason TEXT,
    cancelled_at TIMESTAMP WITH TIME ZONE,
    buyer_remark TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.reviews (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE NOT NULL UNIQUE,
    reviewer_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    target_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    rating INTEGER NOT NULL DEFAULT 5 CHECK (rating >= 1 AND rating <= 5),
    content TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.wallets (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL UNIQUE,
    balance DECIMAL(10,2) NOT NULL DEFAULT 0,
    frozen_balance DECIMAL(10,2) NOT NULL DEFAULT 0,
    total_income DECIMAL(10,2) NOT NULL DEFAULT 0,
    total_expense DECIMAL(10,2) NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.wallet_transactions (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    wallet_id UUID REFERENCES public.wallets(id) ON DELETE CASCADE NOT NULL,
    order_id UUID REFERENCES public.orders(id) ON DELETE SET NULL,
    type TEXT NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    balance_after DECIMAL(10,2) NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.notifications (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'system',
    related_id TEXT,
    is_read BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ==========================================
-- 启用RLS
-- ==========================================
DO $$ BEGIN
    ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.cards ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.market_listings ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$ BEGIN
    ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- ==========================================
-- RLS 策略（用DROP+CREATE避免重复）
-- ==========================================

-- profiles
DO $$ BEGIN DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON public.profiles; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can insert their own profile" ON public.profiles; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Profiles are viewable by everyone" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "Users can insert their own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid()::uuid = id);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid()::uuid = id);

-- cards
DO $$ BEGIN DROP POLICY IF EXISTS "Cards are viewable by everyone" ON public.cards; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can insert their own cards" ON public.cards; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can update own cards" ON public.cards; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can delete own cards" ON public.cards; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Cards are viewable by everyone" ON public.cards FOR SELECT USING (true);
CREATE POLICY "Users can insert their own cards" ON public.cards FOR INSERT WITH CHECK (auth.uid()::uuid = user_id);
CREATE POLICY "Users can update own cards" ON public.cards FOR UPDATE USING (auth.uid()::uuid = user_id);
CREATE POLICY "Users can delete own cards" ON public.cards FOR DELETE USING (auth.uid()::uuid = user_id);

-- messages
DO $$ BEGIN DROP POLICY IF EXISTS "Messages visible to sender or receiver" ON public.messages; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can send messages" ON public.messages; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can update own messages" ON public.messages; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Messages visible to sender or receiver" ON public.messages FOR SELECT USING (auth.uid()::uuid = sender_id OR auth.uid()::uuid = receiver_id);
CREATE POLICY "Users can send messages" ON public.messages FOR INSERT WITH CHECK (auth.uid()::uuid = sender_id);
CREATE POLICY "Users can update own messages" ON public.messages FOR UPDATE USING (auth.uid()::uuid = sender_id);

-- market_listings
DO $$ BEGIN DROP POLICY IF EXISTS "Market listings are viewable by everyone" ON public.market_listings; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can create their own listings" ON public.market_listings; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can update own listings" ON public.market_listings; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Market listings are viewable by everyone" ON public.market_listings FOR SELECT USING (true);
CREATE POLICY "Users can create their own listings" ON public.market_listings FOR INSERT WITH CHECK (auth.uid()::uuid = seller_id);
CREATE POLICY "Users can update own listings" ON public.market_listings FOR UPDATE USING (auth.uid()::uuid = seller_id);

-- favorites
DO $$ BEGIN DROP POLICY IF EXISTS "Favorites are viewable by owner" ON public.favorites; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can insert own favorites" ON public.favorites; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can delete own favorites" ON public.favorites; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Favorites are viewable by owner" ON public.favorites FOR SELECT USING (auth.uid()::uuid = user_id);
CREATE POLICY "Users can insert own favorites" ON public.favorites FOR INSERT WITH CHECK (auth.uid()::uuid = user_id);
CREATE POLICY "Users can delete own favorites" ON public.favorites FOR DELETE USING (auth.uid()::uuid = user_id);

-- orders
DO $$ BEGIN DROP POLICY IF EXISTS "Buyers can view their orders" ON public.orders; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Anyone can create orders" ON public.orders; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Buyers can update their orders" ON public.orders; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Buyers can view their orders" ON public.orders FOR SELECT USING (auth.uid()::uuid = buyer_id OR auth.uid()::uuid = seller_id);
CREATE POLICY "Anyone can create orders" ON public.orders FOR INSERT WITH CHECK (auth.uid()::uuid = buyer_id);
CREATE POLICY "Buyers can update their orders" ON public.orders FOR UPDATE USING (auth.uid()::uuid = buyer_id OR auth.uid()::uuid = seller_id);

-- reviews
DO $$ BEGIN DROP POLICY IF EXISTS "Reviews are viewable by everyone" ON public.reviews; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can create reviews" ON public.reviews; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Reviews are viewable by everyone" ON public.reviews FOR SELECT USING (true);
CREATE POLICY "Users can create reviews" ON public.reviews FOR INSERT WITH CHECK (auth.uid()::uuid = reviewer_id);

-- wallets
DO $$ BEGIN DROP POLICY IF EXISTS "Users can view own wallet" ON public.wallets; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can insert own wallet" ON public.wallets; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can update own wallet" ON public.wallets; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Users can view own wallet" ON public.wallets FOR SELECT USING (auth.uid()::uuid = user_id);
CREATE POLICY "Users can insert own wallet" ON public.wallets FOR INSERT WITH CHECK (auth.uid()::uuid = user_id);
CREATE POLICY "Users can update own wallet" ON public.wallets FOR UPDATE USING (auth.uid()::uuid = user_id);

-- wallet_transactions
DO $$ BEGIN DROP POLICY IF EXISTS "Users can view own transactions" ON public.wallet_transactions; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "System can insert transactions" ON public.wallet_transactions; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Users can view own transactions" ON public.wallet_transactions FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.wallets WHERE id = wallet_id AND user_id = auth.uid()::uuid)
);
CREATE POLICY "System can insert transactions" ON public.wallet_transactions FOR INSERT WITH CHECK (
    EXISTS (SELECT 1 FROM public.wallets WHERE id = wallet_id AND user_id = auth.uid()::uuid)
);

-- notifications
DO $$ BEGIN DROP POLICY IF EXISTS "Users can view own notifications" ON public.notifications; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "System can create notifications" ON public.notifications; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can update own notifications" ON public.notifications; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Users can view own notifications" ON public.notifications FOR SELECT USING (auth.uid()::uuid = user_id);
CREATE POLICY "System can create notifications" ON public.notifications FOR INSERT WITH CHECK (true);
CREATE POLICY "Users can update own notifications" ON public.notifications FOR UPDATE USING (auth.uid()::uuid = user_id);

-- ==========================================
-- 存储桶
-- ==========================================
INSERT INTO storage.buckets (id, name, public) 
VALUES ('card-images', 'card-images', true)
ON CONFLICT (id) DO NOTHING;

DO $$ BEGIN DROP POLICY IF EXISTS "Card images are publicly accessible" ON storage.objects; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Authenticated users can upload card images" ON storage.objects; EXCEPTION WHEN OTHERS THEN NULL; END $$;
DO $$ BEGIN DROP POLICY IF EXISTS "Users can delete their own card images" ON storage.objects; EXCEPTION WHEN OTHERS THEN NULL; END $$;

CREATE POLICY "Card images are publicly accessible" ON storage.objects FOR SELECT USING (bucket_id = 'card-images');
CREATE POLICY "Authenticated users can upload card images" ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'card-images' AND auth.role() = 'authenticated');
CREATE POLICY "Users can delete their own card images" ON storage.objects FOR DELETE USING (bucket_id = 'card-images' AND auth.uid()::uuid = owner);

-- ==========================================
-- 触发器
-- ==========================================
DO $$ BEGIN DROP TRIGGER IF EXISTS update_profiles_updated_at ON public.profiles; EXCEPTION WHEN OTHERS THEN NULL; END $$;
CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DO $$ BEGIN DROP TRIGGER IF EXISTS update_cards_updated_at ON public.cards; EXCEPTION WHEN OTHERS THEN NULL; END $$;
CREATE TRIGGER update_cards_updated_at BEFORE UPDATE ON public.cards FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DO $$ BEGIN DROP TRIGGER IF EXISTS update_market_listings_updated_at ON public.market_listings; EXCEPTION WHEN OTHERS THEN NULL; END $$;
CREATE TRIGGER update_market_listings_updated_at BEFORE UPDATE ON public.market_listings FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DO $$ BEGIN DROP TRIGGER IF EXISTS update_orders_updated_at ON public.orders; EXCEPTION WHEN OTHERS THEN NULL; END $$;
CREATE TRIGGER update_orders_updated_at BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DO $$ BEGIN DROP TRIGGER IF EXISTS update_wallets_updated_at ON public.wallets; EXCEPTION WHEN OTHERS THEN NULL; END $$;
CREATE TRIGGER update_wallets_updated_at BEFORE UPDATE ON public.wallets FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ==========================================
-- 索引
-- ==========================================
CREATE INDEX IF NOT EXISTS idx_orders_buyer ON public.orders(buyer_id);
CREATE INDEX IF NOT EXISTS idx_orders_seller ON public.orders(seller_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_listing ON public.orders(listing_id);
CREATE INDEX IF NOT EXISTS idx_orders_order_no ON public.orders(order_no);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_read ON public.notifications(user_id, is_read);
