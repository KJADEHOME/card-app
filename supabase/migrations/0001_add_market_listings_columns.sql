-- ============================================
-- 迁移：为 market_listings 添加缺失字段
-- ============================================
-- 原表只定义了 card_id/seller_id/price/status
-- 前端发布和读取需要 name/series/rarity/description/image_url/type/type
-- 这些字段前端一直靠 Supabase 宽松写入勉强工作
-- 执行此迁移正式补全 schema

-- 1. 添加卡牌基本信息字段
ALTER TABLE public.market_listings
  ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT '未命名',
  ADD COLUMN IF NOT EXISTS series TEXT NOT NULL DEFAULT '游戏王',
  ADD COLUMN IF NOT EXISTS rarity TEXT NOT NULL DEFAULT 'N',
  ADD COLUMN IF NOT EXISTS description TEXT,
  ADD COLUMN IF NOT EXISTS image_url TEXT,
  ADD COLUMN IF NOT EXISTS type TEXT DEFAULT 'sell',  -- sell=卖，buy=买
  ADD COLUMN IF NOT EXISTS card_id UUID;              -- 保留原字段但改为可选

-- 2. 让 card_id 变成可选（新增发布不再强制要求关联 cards 表）
-- （已有外键约束只能改列类型绕过）
ALTER TABLE public.market_listings
  ALTER COLUMN card_id DROP NOT NULL;

-- 3. 建立索引（已有 listing_id 索引，加 serie/type/status 方便查询）
CREATE INDEX IF NOT EXISTS idx_market_listings_series ON public.market_listings(series);
CREATE INDEX IF NOT EXISTS idx_market_listings_type ON public.market_listings(type);
CREATE INDEX IF NOT EXISTS idx_market_listings_status ON public.market_listings(status);

-- 4. 给现有 active 记录补默认值（之前宽松写入的条目 name 等字段可能为空）
UPDATE public.market_listings
SET
  name = COALESCE(NULLIF(TRIM(name), ''), '未命名'),
  series = COALESCE(NULLIF(TRIM(series), ''), '游戏王'),
  rarity = COALESCE(NULLIF(TRIM(rarity), ''), 'N')
WHERE name IS NULL OR name = '' OR series IS NULL OR series = '' OR rarity IS NULL OR rarity = '';

COMMENT ON COLUMN public.market_listings.name IS '卡牌名称';
COMMENT ON COLUMN public.market_listings.series IS '卡牌系列：游戏王/宝可梦/万智牌/数码宝贝/其他';
COMMENT ON COLUMN public.market_listings.rarity IS '稀有度：N/R/SR/UR/SSR/SEC/PR等';
COMMENT ON COLUMN public.market_listings.description IS '卡牌描述/交易说明';
COMMENT ON COLUMN public.market_listings.image_url IS '卡牌图片URL';
COMMENT ON COLUMN public.market_listings.type IS '发布类型：sell=出售，buy=求购';
