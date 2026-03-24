-- 卡域 Supabase 数据库初始化脚本（修复版）

-- 1. 用户资料表
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    avatar_url TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 2. 卡牌表
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
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- 启用RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cards ENABLE ROW LEVEL SECURITY;

-- 创建策略
CREATE POLICY "Profiles are viewable by everyone" ON public.profiles FOR SELECT USING (true);
CREATE POLICY "Users can insert their own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);

CREATE POLICY "Cards are viewable by everyone" ON public.cards FOR SELECT USING (true);
CREATE POLICY "Users can insert their own cards" ON public.cards FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own cards" ON public.cards FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own cards" ON public.cards FOR DELETE USING (auth.uid() = user_id);

-- 注意：存储桶请通过Supabase控制台手动创建
-- 1. 进入 Storage
-- 2. 点击 "New bucket"
-- 3. 名称填：card-images
-- 4. 勾选 "Public bucket"
-- 5. 点击 Save