-- ============================================================
-- 0034: 分层卡牌经济系统
-- 核心架构: 一级市场(盲盒/未拆封) + 二级市场(已拆卡) + 周边商品
-- 
-- 🎯 一级市场 = 不确定性商品（盲盒）→ 无AI，手动录入，管理员定价
-- 🎯 二级市场 = 确定性资产（卡牌）  → AI识卡录入，mark_price动态定价
-- 🎯 周边商品 = 标准电商            → 完全手动，无AI
--
-- 商品流:
--   一级: admin录入 → sealed_products → 预售/直接销售
--   二级: 拆盒 → AI识卡 → card_market → mark_price → 交易
--   周边: admin录入 → merchandise → 标准电商
-- ============================================================

-- ============================================================
-- Part 1: 一级市场 — sealed_products 表 (盲盒/未拆封商品)
-- ============================================================
CREATE TABLE IF NOT EXISTS sealed_products (
  id                UUID PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
  admin_id          UUID REFERENCES admins(id) ON DELETE SET NULL,
  
  -- 商品基本信息
  name              TEXT NOT NULL,                    -- 商品名称(如"2024 Pokémon Booster Box")
  name_en           TEXT,                             -- 英文名
  product_type      TEXT NOT NULL CHECK (product_type IN (
    'sealed_box',     -- 整盒( Booster Box / 整盒 )
    'booster_pack',   -- 单包( Booster Pack / 补充包 )
    'starter_deck',   -- 预组( Starter Deck / 预组牌组 )
    'elite_trainer',  -- ETB( Elite Trainer Box )
    'collection_box', -- 收藏盒/礼盒
    'display_box'     -- 陈列盒( Display Box )
  )),
  -- 所属系列/品牌
  brand             TEXT NOT NULL DEFAULT 'pokemon',  -- 品牌(pokemon/yugioh/magic等)
  series_name       TEXT,                             -- 系列名(如"Scarlet & Violet")
  series_code       TEXT,                             -- 系列代号(如"sv4pt5")
  language          TEXT NOT NULL DEFAULT 'japanese' CHECK (language IN (
    'japanese', 'english', 'chinese', 'korean', 'mixed'
  )),
  
  -- SKU管理
  sku               TEXT NOT NULL UNIQUE,             -- SKU编号(唯一)
  barcode           TEXT,                             -- 条形码/UPC
  
  -- 商品描述
  description       TEXT,                             -- 商品描述
  images            TEXT[] DEFAULT '{}',              -- 图片URL列表
  thumbnail_url     TEXT,                             -- 缩略图
  
  -- 概率/规格信息(一级市场特色)
  packs_per_box     INTEGER,                          -- 每盒包数(如36包)
  cards_per_pack    INTEGER,                          -- 每包卡数(如5张)
  total_cards       INTEGER,                          -- 总卡数(含隐张等)
  guaranteed_hits   TEXT,                             -- 保底信息(如"每盒至少1张SR")
  rarity_distribution JSONB DEFAULT '{}',             -- 概率分布(如{"SR": "1/6", "UR": "1/36"})
  
  -- 定价(管理员设定，非AI)
  cost_price        NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (cost_price >= 0),  -- 进货成本
  listing_price     NUMERIC(10,2) NOT NULL CHECK (listing_price > 0),          -- 售价(管理员定价)
  original_price    NUMERIC(10,2),                    -- 原价/参考价
  member_price      NUMERIC(10,2),                    -- 会员价(可选)
  
  -- 库存管理
  stock_quantity    INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
  reserved_quantity INTEGER NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),
  sold_quantity     INTEGER NOT NULL DEFAULT 0 CHECK (sold_quantity >= 0),
  min_order_quantity INTEGER NOT NULL DEFAULT 1,      -- 最小购买数量
  max_order_quantity INTEGER NOT NULL DEFAULT 10,     -- 最大购买数量
  
  -- 预售支持
  is_pre_order      BOOLEAN NOT NULL DEFAULT false,   -- 是否预售
  pre_order_start   TIMESTAMPTZ,                      -- 预售开始时间
  pre_order_end     TIMESTAMPTZ,                      -- 预售结束时间
  release_date      DATE,                             -- 发售日期
  shipping_date     DATE,                             -- 预计发货日期
  
  -- 状态
  status            TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
    'draft',        -- 草稿(未上架)
    'active',       -- 在售
    'on_sale',      -- 促销
    'pre_order',    -- 预售中
    'sold_out',     -- 已售罄
    'inactive',     -- 已下架
    'discontinued'  -- 已停产
  )),
  
  -- 物流/附加
  weight_grams     INTEGER,                           -- 重量(克)
  shipping_fee     NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (shipping_fee >= 0),
  platform_fee_pct NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (platform_fee_pct >= 0),
  
  -- 元数据
  tags             TEXT[] DEFAULT '{}',
  sort_order       INTEGER NOT NULL DEFAULT 0,
  view_count       INTEGER NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- available_quantity 为生成列(自动计算)
ALTER TABLE sealed_products ADD COLUMN IF NOT EXISTS available_quantity INTEGER
  GENERATED ALWAYS AS (stock_quantity - reserved_quantity - sold_quantity) STORED;

COMMENT ON TABLE sealed_products IS '一级市场商品 — 盲盒/未拆封/整盒等概率商品, 无AI识别, 管理员定价';
COMMENT ON COLUMN sealed_products.product_type IS 'sealed_box=整盒, booster_pack=单包, starter_deck=预组, elite_trainer=ETB, collection_box=收藏盒, display_box=陈列盒';
COMMENT ON COLUMN sealed_products.sku IS 'SKU编号(唯一), 管理员手动设定';
COMMENT ON COLUMN sealed_products.guaranteed_hits IS '保底信息, 如"每盒至少1张SR"';
COMMENT ON COLUMN sealed_products.rarity_distribution IS '概率分布JSON, 如{"SR":"1/6","UR":"1/36"}';
COMMENT ON COLUMN sealed_products.is_pre_order IS '是否预售商品';

-- ============================================================
-- Part 2: 一级市场 — sealed_product_orders 表 (盲盒订单)
-- ============================================================
CREATE TABLE IF NOT EXISTS sealed_product_orders (
  id                UUID PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
  order_no          TEXT NOT NULL UNIQUE,             -- 订单号(自动生成)
  user_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  sealed_product_id UUID NOT NULL REFERENCES sealed_products(id),
  
  -- 订单详情
  quantity          INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price        NUMERIC(10,2) NOT NULL,           -- 单价(下单时锁定)
  total_amount      NUMERIC(10,2) NOT NULL,           -- 总价
  shipping_fee      NUMERIC(10,2) NOT NULL DEFAULT 0,
  platform_fee      NUMERIC(10,2) NOT NULL DEFAULT 0,
  
  -- 订单状态
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending',       -- 待确认(预售下单后等待发货)
    'confirmed',     -- 已确认(管理员确认订单)
    'paid',          -- 已付款
    'shipping',      -- 已发货
    'delivered',     -- 已送达
    'cancelled',     -- 已取消
    'refunded'       -- 已退款
  )),
  payment_status    TEXT NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN (
    'unpaid', 'paid', 'refunded'
  )),
  payment_method    TEXT,                             -- 支付方式
  transaction_id    TEXT,                             -- 交易流水号
  
  -- 预售相关
  is_pre_order      BOOLEAN NOT NULL DEFAULT false,
  estimated_ship_date DATE,                           -- 预计发货日期
  
  -- 物流
  tracking_no       TEXT,
  shipping_carrier  TEXT,
  buyer_address     JSONB,                            -- 收货地址
  
  -- 时间戳
  paid_at           TIMESTAMPTZ,
  shipped_at        TIMESTAMPTZ,
  delivered_at      TIMESTAMPTZ,
  cancelled_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE sealed_product_orders IS '一级市场订单 — 盲盒/未拆封商品购买订单';
COMMENT ON COLUMN sealed_product_orders.unit_price IS '下单时锁定价格, 不随管理员调价变动';

-- ============================================================
-- Part 3: 周边商品 — merchandise 表
-- ============================================================
CREATE TABLE IF NOT EXISTS merchandise (
  id                UUID PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
  admin_id          UUID REFERENCES admins(id) ON DELETE SET NULL,
  
  -- 商品基本信息
  name              TEXT NOT NULL,
  name_en           TEXT,
  merch_type        TEXT NOT NULL CHECK (merch_type IN (
    'accessories',    -- 配件(卡套/卡垫/卡盒等)
    'display',        -- 展示(展示架/卡框等)
    'storage',        -- 收纳(收藏箱/收纳包等)
    'apparel',        -- 服饰(T恤/帽子等)
    'stationery',     -- 文具(贴纸/笔记本等)
    'figure',         -- 手办/模型
    'other'           -- 其他
  )),
  
  -- SKU
  sku               TEXT NOT NULL UNIQUE,
  barcode           TEXT,
  
  -- 商品描述
  description       TEXT,
  images            TEXT[] DEFAULT '{}',
  thumbnail_url     TEXT,
  
  -- 规格
  material          TEXT,                             -- 材质
  color             TEXT,                             -- 颜色/款式
  size              TEXT,                             -- 尺寸规格
  weight_grams      INTEGER,                         -- 重量
  
  -- 定价(管理员设定，标准电商)
  cost_price        NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (cost_price >= 0),
  listing_price     NUMERIC(10,2) NOT NULL CHECK (listing_price > 0),
  original_price    NUMERIC(10,2),                   -- 原价(用于显示折扣)
  member_price      NUMERIC(10,2),                   -- 会员价
  
  -- 库存
  stock_quantity    INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
  reserved_quantity INTEGER NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),
  sold_quantity     INTEGER NOT NULL DEFAULT 0 CHECK (sold_quantity >= 0),
  
  -- 状态
  status            TEXT NOT NULL DEFAULT 'draft' CHECK (status IN (
    'draft', 'active', 'on_sale', 'sold_out', 'inactive', 'discontinued'
  )),
  
  -- 物流/附加
  shipping_fee      NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (shipping_fee >= 0),
  platform_fee_pct  NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (platform_fee_pct >= 0),
  
  -- 元数据
  tags              TEXT[] DEFAULT '{}',
  sort_order        INTEGER NOT NULL DEFAULT 0,
  view_count        INTEGER NOT NULL DEFAULT 0,
  brand             TEXT,                             -- 品牌
  related_card_series TEXT,                           -- 关联卡牌系列(如配件适用于哪个系列)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- available_quantity 为生成列
ALTER TABLE merchandise ADD COLUMN IF NOT EXISTS available_quantity INTEGER
  GENERATED ALWAYS AS (stock_quantity - reserved_quantity - sold_quantity) STORED;

COMMENT ON TABLE merchandise IS '周边商品 — 卡套/卡垫/展示架等标准电商商品, 完全手动录入, 无AI';

-- ============================================================
-- Part 4: 周边商品 — merchandise_orders 表
-- ============================================================
CREATE TABLE IF NOT EXISTS merchandise_orders (
  id                UUID PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
  order_no          TEXT NOT NULL UNIQUE,
  user_id           UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  merchandise_id    UUID NOT NULL REFERENCES merchandise(id),
  
  quantity          INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  unit_price        NUMERIC(10,2) NOT NULL,
  total_amount      NUMERIC(10,2) NOT NULL,
  shipping_fee      NUMERIC(10,2) NOT NULL DEFAULT 0,
  platform_fee      NUMERIC(10,2) NOT NULL DEFAULT 0,
  
  -- 规格(下单时锁定)
  selected_color    TEXT,
  selected_size     TEXT,
  
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN (
    'pending', 'confirmed', 'paid', 'shipping', 'delivered', 'cancelled', 'refunded'
  )),
  payment_status    TEXT NOT NULL DEFAULT 'unpaid' CHECK (payment_status IN ('unpaid', 'paid', 'refunded')),
  payment_method    TEXT,
  transaction_id    TEXT,
  
  tracking_no       TEXT,
  shipping_carrier  TEXT,
  buyer_address     JSONB,
  
  paid_at           TIMESTAMPTZ,
  shipped_at        TIMESTAMPTZ,
  delivered_at      TIMESTAMPTZ,
  cancelled_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE merchandise_orders IS '周边商品订单 — 标准电商购买';

-- ============================================================
-- Part 5: card_market 角色明确化 — 二级市场专属
-- ============================================================

-- card_market 添加 market_tier 字段明确二级市场定位
ALTER TABLE card_market ADD COLUMN IF NOT EXISTS market_tier TEXT NOT NULL DEFAULT 'secondary'
  CHECK (market_tier = 'secondary');  -- 强制: card_market 仅用于二级市场

COMMENT ON COLUMN card_market.market_tier IS '二级市场专属标记 — AI识卡后录入此表, mark_price动态定价';
COMMENT ON TABLE card_market IS '二级市场价格表 — 仅用于已拆卡/单卡交易, AI识卡→card_market→mark_price';

-- 添加 card_market ↔ 二级市场交易的关联说明
-- card_market 的唯一键 (card_name, series, rarity, market) 代表一张"确定性的卡牌资产"

-- ============================================================
-- Part 6: user_collections 角色明确化 — 二级市场资产登记
-- ============================================================

-- user_collections 添加 market_tier 标记
ALTER TABLE user_collections ADD COLUMN IF NOT EXISTS market_tier TEXT NOT NULL DEFAULT 'secondary'
  CHECK (market_tier = 'secondary');

-- 移除 is_platform_stock (平台不再自建库存)
ALTER TABLE user_collections DROP COLUMN IF EXISTS is_platform_stock;

COMMENT ON COLUMN user_collections.market_tier IS '二级市场资产 — 用户拆盒后的卡牌收藏';

-- ============================================================
-- Part 7: platform_cards 重新定位 — 仅用于二级市场官方卡牌
-- ============================================================

-- platform_cards 添加 market_tier 标记
ALTER TABLE platform_cards ADD COLUMN IF NOT EXISTS market_tier TEXT NOT NULL DEFAULT 'secondary'
  CHECK (market_tier = 'secondary');

-- 移除 source CHECK约束(仅允许platform) — 改为允许platform来源的二级市场卡
-- 先删除旧约束再添加新约束
ALTER TABLE platform_cards DROP CONSTRAINT IF EXISTS platform_cards_source_check;
ALTER TABLE platform_cards ADD CONSTRAINT platform_cards_source_check
  CHECK (source IN ('platform', 'secondary_official'));

COMMENT ON COLUMN platform_cards.market_tier IS '二级市场 — 平台官方发行的已确认单卡(非盲盒)';
COMMENT ON TABLE platform_cards IS '二级市场官方卡牌 — 已确认卡牌资产的官方发行, 非盲盒/一级市场商品';

-- ============================================================
-- Part 8: 统一商品体系视图 — three_tier_product_catalog
-- ============================================================
CREATE OR REPLACE VIEW three_tier_product_catalog AS
-- 一级市场: 盲盒/未拆封
SELECT
  sp.id AS product_id,
  'primary' AS market_tier,
  'sealed_product' AS product_source,
  sp.name,
  sp.name_en,
  sp.product_type,
  sp.brand,
  sp.series_name,
  sp.language,
  sp.sku,
  sp.listing_price,
  sp.cost_price,
  NULL::NUMERIC AS mark_price,          -- 一级市场无mark_price
  NULL::TEXT AS price_source,           -- 一级市场无动态定价
  sp.thumbnail_url,
  sp.images[1] AS primary_image,
  sp.stock_quantity,
  sp.available_quantity,
  sp.status,
  sp.is_pre_order,
  sp.release_date,
  sp.created_at
FROM sealed_products sp
WHERE sp.status IN ('active', 'on_sale', 'pre_order')

UNION ALL

-- 二级市场: 已拆卡(平台官方发行)
SELECT
  pc.id AS product_id,
  'secondary' AS market_tier,
  'platform_card' AS product_source,
  pc.name,
  pc.name_en,
  'single_card' AS product_type,        -- 二级市场=单卡
  NULL::TEXT AS brand,
  pc.set_name AS series_name,
  NULL::TEXT AS language,
  NULL::TEXT AS sku,
  pc.listing_price,
  pc.initial_cost_price AS cost_price,
  cm.mark_price,                         -- 二级市场有mark_price
  cm.price_source,
  pc.thumbnail_url,
  pc.card_image_url AS primary_image,
  pc.stock_quantity,
  pc.available_quantity,
  pc.status,
  false AS is_pre_order,
  NULL::DATE AS release_date,
  pc.created_at
FROM platform_cards pc
LEFT JOIN card_market cm ON cm.id = pc.card_market_id
WHERE pc.status IN ('active', 'on_sale')

UNION ALL

-- 周边商品
SELECT
  m.id AS product_id,
  'merchandise' AS market_tier,
  'merchandise' AS product_source,
  m.name,
  m.name_en,
  m.merch_type AS product_type,
  m.brand,
  NULL::TEXT AS series_name,
  NULL::TEXT AS language,
  m.sku,
  m.listing_price,
  m.cost_price,
  NULL::NUMERIC AS mark_price,          -- 周边无mark_price
  NULL::TEXT AS price_source,
  m.thumbnail_url,
  m.images[1] AS primary_image,
  m.stock_quantity,
  m.available_quantity,
  m.status,
  false AS is_pre_order,
  NULL::DATE AS release_date,
  m.created_at
FROM merchandise m
WHERE m.status IN ('active', 'on_sale');

COMMENT ON VIEW three_tier_product_catalog IS '三层市场统一商品目录 — primary(盲盒) + secondary(卡牌) + merchandise(周边)';

-- ============================================================
-- Part 9: 一级市场商品录入视图 — primary_market_store
-- ============================================================
CREATE OR REPLACE VIEW primary_market_store AS
SELECT
  sp.id,
  sp.name,
  sp.name_en,
  sp.product_type,
  sp.brand,
  sp.series_name,
  sp.series_code,
  sp.language,
  sp.sku,
  sp.listing_price,
  sp.original_price,
  sp.member_price,
  sp.cost_price,
  sp.thumbnail_url,
  sp.images,
  sp.description,
  sp.packs_per_box,
  sp.cards_per_pack,
  sp.total_cards,
  sp.guaranteed_hits,
  sp.rarity_distribution,
  sp.stock_quantity,
  sp.reserved_quantity,
  sp.sold_quantity,
  sp.available_quantity,
  sp.min_order_quantity,
  sp.max_order_quantity,
  sp.is_pre_order,
  sp.pre_order_start,
  sp.pre_order_end,
  sp.release_date,
  sp.shipping_date,
  sp.shipping_fee,
  sp.platform_fee_pct,
  sp.status,
  sp.tags,
  sp.view_count,
  sp.created_at,
  -- 折扣信息(如果有original_price)
  CASE
    WHEN sp.original_price IS NOT NULL AND sp.original_price > sp.listing_price
    THEN ROUND(((sp.original_price - sp.listing_price) / sp.original_price) * 100, 0)
    ELSE 0
  END AS discount_pct
FROM sealed_products sp
WHERE sp.status IN ('active', 'on_sale', 'pre_order')
ORDER BY sp.sort_order ASC, sp.created_at DESC;

COMMENT ON VIEW primary_market_store IS '一级市场商店 — 盲盒/未拆封商品列表';

-- ============================================================
-- Part 10: 二级市场交易视图 — secondary_market_list
-- ============================================================
CREATE OR REPLACE VIEW secondary_market_list AS
SELECT
  c.id AS consignment_id,
  c.seller_id,
  p.username AS seller_name,
  c.card_name,
  c.card_name_en,
  c.card_image,
  c.series,
  c.rarity,
  c.card_category,
  c.condition,
  c.description,
  c.asking_price,
  c.quantity,
  c.shipping_fee,
  c.platform_fee_pct,
  c.status,
  c.tags,
  c.view_count,
  c.wishlist_count,
  c.listed_at,
  -- 二级市场 mark_price 参考
  cm.final_price AS mark_price,
  cm.mark_price AS latest_mark_price,
  cm.price_source,
  cm.market_state,
  cm.activity_score,
  -- 价格对比(asking_price vs mark_price)
  CASE
    WHEN cm.mark_price > 0 AND c.asking_price > 0
    THEN ROUND(((c.asking_price - cm.mark_price) / cm.mark_price) * 100, 2)
    ELSE NULL
  END AS price_vs_mark_pct,
  -- 来源标识
  CASE c.is_platform_sale WHEN true THEN 'platform' ELSE 'user' END AS listing_source
FROM consignments c
JOIN profiles p ON p.id = c.seller_id
LEFT JOIN card_market cm ON cm.card_name = c.card_name 
  AND cm.series = c.series AND cm.rarity = c.rarity
  AND cm.market = COALESCE(c.card_category, 'pokemon')
WHERE c.status = 'active'
ORDER BY c.is_platform_sale DESC, c.created_at DESC;

COMMENT ON VIEW secondary_market_list IS '二级市场交易列表 — 已拆卡交易, 含mark_price参考价';

-- ============================================================
-- Part 11: 周边商品视图 — merchandise_store
-- ============================================================
CREATE OR REPLACE VIEW merchandise_store AS
SELECT
  m.id,
  m.name,
  m.name_en,
  m.merch_type,
  m.brand,
  m.sku,
  m.listing_price,
  m.original_price,
  m.member_price,
  m.thumbnail_url,
  m.images,
  m.description,
  m.material,
  m.color,
  m.size,
  m.stock_quantity,
  m.available_quantity,
  m.shipping_fee,
  m.status,
  m.tags,
  m.view_count,
  m.related_card_series,
  m.created_at,
  CASE
    WHEN m.original_price IS NOT NULL AND m.original_price > m.listing_price
    THEN ROUND(((m.original_price - m.listing_price) / m.original_price) * 100, 0)
    ELSE 0
  END AS discount_pct
FROM merchandise m
WHERE m.status IN ('active', 'on_sale')
ORDER BY m.sort_order ASC, m.created_at DESC;

COMMENT ON VIEW merchandise_store IS '周边商品商店 — 卡套/卡垫/展示架等';

-- ============================================================
-- Part 12: RPC — admin_create_sealed_product()
-- 管理员创建一级市场商品(盲盒/未拆封)
-- NOTE: #variable_conflict use_column 解决 RETURNS TABLE sku 与表列歧义
-- ============================================================
CREATE OR REPLACE FUNCTION admin_create_sealed_product(
  p_admin_id UUID, p_name TEXT DEFAULT 'New Product',
  p_product_type TEXT DEFAULT 'sealed_box', p_sku TEXT DEFAULT 'SKU-TEMP',
  p_listing_price NUMERIC DEFAULT 100.00,
  p_name_en TEXT DEFAULT NULL, p_brand TEXT DEFAULT 'pokemon',
  p_series_name TEXT DEFAULT NULL, p_series_code TEXT DEFAULT NULL,
  p_language TEXT DEFAULT 'japanese', p_barcode TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL, p_images TEXT[] DEFAULT NULL,
  p_thumbnail_url TEXT DEFAULT NULL,
  p_packs_per_box INTEGER DEFAULT NULL, p_cards_per_pack INTEGER DEFAULT NULL,
  p_total_cards INTEGER DEFAULT NULL, p_guaranteed_hits TEXT DEFAULT NULL,
  p_rarity_distribution JSONB DEFAULT '{}',
  p_cost_price NUMERIC DEFAULT 0, p_original_price NUMERIC DEFAULT NULL,
  p_member_price NUMERIC DEFAULT NULL, p_stock_quantity INTEGER DEFAULT 0,
  p_min_order_quantity INTEGER DEFAULT 1, p_max_order_quantity INTEGER DEFAULT 10,
  p_is_pre_order BOOLEAN DEFAULT false,
  p_pre_order_start TIMESTAMPTZ DEFAULT NULL, p_pre_order_end TIMESTAMPTZ DEFAULT NULL,
  p_release_date DATE DEFAULT NULL, p_shipping_date DATE DEFAULT NULL,
  p_weight_grams INTEGER DEFAULT NULL, p_shipping_fee NUMERIC DEFAULT 0,
  p_platform_fee_pct NUMERIC DEFAULT 0, p_tags TEXT[] DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, product_id UUID, sku TEXT, message TEXT)
AS $func$
#variable_conflict use_column
DECLARE
  v_admin_status TEXT;
  v_product_id UUID;
  v_sku TEXT;
BEGIN
  SELECT status INTO v_admin_status FROM public.admins WHERE id = p_admin_id;
  IF v_admin_status IS NULL OR v_admin_status != 'active' THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 'Admin not found or inactive'::TEXT;
    RETURN;
  END IF;
  INSERT INTO public.sealed_products (
    admin_id, name, name_en, product_type, brand, series_name, series_code,
    language, sku, barcode, description, images, thumbnail_url,
    packs_per_box, cards_per_pack, total_cards, guaranteed_hits, rarity_distribution,
    cost_price, listing_price, original_price, member_price,
    stock_quantity, min_order_quantity, max_order_quantity,
    is_pre_order, pre_order_start, pre_order_end, release_date, shipping_date,
    weight_grams, shipping_fee, platform_fee_pct, tags, status
  ) VALUES (
    p_admin_id, p_name, p_name_en, p_product_type, p_brand, p_series_name, p_series_code,
    p_language, p_sku, p_barcode, p_description, p_images, p_thumbnail_url,
    p_packs_per_box, p_cards_per_pack, p_total_cards, p_guaranteed_hits, p_rarity_distribution,
    p_cost_price, p_listing_price, p_original_price, p_member_price,
    p_stock_quantity, p_min_order_quantity, p_max_order_quantity,
    p_is_pre_order, p_pre_order_start, p_pre_order_end, p_release_date, p_shipping_date,
    p_weight_grams, p_shipping_fee, p_platform_fee_pct, p_tags, 'draft'
  ) RETURNING id, sku INTO v_product_id, v_sku;
  INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
  VALUES (p_admin_id, 'create_sealed_product', 'sealed_product', v_product_id,
    jsonb_build_object('name', p_name, 'sku', v_sku, 'product_type', p_product_type));
  RETURN QUERY SELECT true, v_product_id, v_sku, 'Sealed product created'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION admin_create_sealed_product() IS '管理员创建一级市场商品(盲盒/未拆封) — 无AI, 管理员定价';

-- ============================================================
-- Part 13: RPC — admin_update_sealed_product()
-- 管理员更新一级市场商品
-- NOTE: 所有参数有默认值(42P13合规), public.前缀(search_path='')
-- ============================================================
CREATE OR REPLACE FUNCTION admin_update_sealed_product(
  p_admin_id UUID, p_product_id UUID DEFAULT NULL,
  p_name TEXT DEFAULT NULL, p_product_type TEXT DEFAULT NULL,
  p_sku TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL,
  p_images TEXT[] DEFAULT NULL, p_thumbnail_url TEXT DEFAULT NULL,
  p_packs_per_box INTEGER DEFAULT NULL, p_cards_per_pack INTEGER DEFAULT NULL,
  p_total_cards INTEGER DEFAULT NULL, p_guaranteed_hits TEXT DEFAULT NULL,
  p_rarity_distribution JSONB DEFAULT NULL, p_cost_price NUMERIC DEFAULT NULL,
  p_listing_price NUMERIC DEFAULT NULL, p_original_price NUMERIC DEFAULT NULL,
  p_member_price NUMERIC DEFAULT NULL, p_stock_quantity INTEGER DEFAULT NULL,
  p_min_order_quantity INTEGER DEFAULT NULL, p_max_order_quantity INTEGER DEFAULT NULL,
  p_is_pre_order BOOLEAN DEFAULT NULL, p_release_date DATE DEFAULT NULL,
  p_shipping_date DATE DEFAULT NULL, p_shipping_fee NUMERIC DEFAULT NULL,
  p_status TEXT DEFAULT NULL, p_tags TEXT[] DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT)
AS $func$
DECLARE v_admin_status TEXT;
BEGIN
  SELECT status INTO v_admin_status FROM public.admins WHERE id = p_admin_id;
  IF v_admin_status IS NULL OR v_admin_status != 'active' THEN
    RETURN QUERY SELECT false, 'Admin not authorized'::TEXT; RETURN;
  END IF;
  UPDATE public.sealed_products SET
    name = COALESCE(p_name, public.sealed_products.name),
    product_type = COALESCE(p_product_type, public.sealed_products.product_type),
    sku = COALESCE(p_sku, public.sealed_products.sku),
    description = COALESCE(p_description, public.sealed_products.description),
    images = COALESCE(p_images, public.sealed_products.images),
    thumbnail_url = COALESCE(p_thumbnail_url, public.sealed_products.thumbnail_url),
    packs_per_box = COALESCE(p_packs_per_box, public.sealed_products.packs_per_box),
    cards_per_pack = COALESCE(p_cards_per_pack, public.sealed_products.cards_per_pack),
    total_cards = COALESCE(p_total_cards, public.sealed_products.total_cards),
    guaranteed_hits = COALESCE(p_guaranteed_hits, public.sealed_products.guaranteed_hits),
    rarity_distribution = COALESCE(p_rarity_distribution, public.sealed_products.rarity_distribution),
    cost_price = COALESCE(p_cost_price, public.sealed_products.cost_price),
    listing_price = COALESCE(p_listing_price, public.sealed_products.listing_price),
    original_price = COALESCE(p_original_price, public.sealed_products.original_price),
    member_price = COALESCE(p_member_price, public.sealed_products.member_price),
    stock_quantity = COALESCE(p_stock_quantity, public.sealed_products.stock_quantity),
    min_order_quantity = COALESCE(p_min_order_quantity, public.sealed_products.min_order_quantity),
    max_order_quantity = COALESCE(p_max_order_quantity, public.sealed_products.max_order_quantity),
    is_pre_order = COALESCE(p_is_pre_order, public.sealed_products.is_pre_order),
    release_date = COALESCE(p_release_date, public.sealed_products.release_date),
    shipping_date = COALESCE(p_shipping_date, public.sealed_products.shipping_date),
    shipping_fee = COALESCE(p_shipping_fee, public.sealed_products.shipping_fee),
    status = COALESCE(p_status, public.sealed_products.status),
    tags = COALESCE(p_tags, public.sealed_products.tags),
    updated_at = now()
  WHERE id = p_product_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'Product not found'::TEXT; RETURN;
  END IF;
  RETURN QUERY SELECT true, 'Sealed product updated'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION admin_update_sealed_product() IS '管理员更新一级市场商品信息';

-- ============================================================
-- Part 14: RPC — create_sealed_product_order()
-- 用户下单购买一级市场商品
-- NOTE: #variable_conflict use_column 解决 RETURNS TABLE order_no 与表列歧义
-- ============================================================
CREATE OR REPLACE FUNCTION create_sealed_product_order(
  p_user_id UUID, p_product_id UUID, p_quantity INTEGER DEFAULT 1,
  p_buyer_address JSONB DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, order_id UUID, order_no TEXT, total_amount NUMERIC, message TEXT)
AS $func$
#variable_conflict use_column
DECLARE
  v_product_rec RECORD; v_order_no_val TEXT; v_order_id UUID;
  v_total_amount NUMERIC(10,2); v_available INTEGER;
BEGIN
  SELECT * INTO v_product_rec FROM public.sealed_products WHERE id = p_product_id;
  IF v_product_rec IS NULL THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Product not found'::TEXT; RETURN;
  END IF;
  IF v_product_rec.status NOT IN ('active', 'on_sale', 'pre_order') THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Product not available'::TEXT; RETURN;
  END IF;
  IF v_product_rec.is_pre_order THEN
    IF now() < v_product_rec.pre_order_start OR now() > v_product_rec.pre_order_end THEN
      RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Pre-order not active'::TEXT; RETURN;
    END IF;
  END IF;
  IF p_quantity < v_product_rec.min_order_quantity THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Below minimum order qty'::TEXT; RETURN;
  END IF;
  IF p_quantity > v_product_rec.max_order_quantity THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Above maximum order qty'::TEXT; RETURN;
  END IF;
  v_available := v_product_rec.stock_quantity - v_product_rec.reserved_quantity - v_product_rec.sold_quantity;
  IF v_available < p_quantity THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Insufficient stock'::TEXT; RETURN;
  END IF;
  v_total_amount := v_product_rec.listing_price * p_quantity + v_product_rec.shipping_fee;
  v_order_no_val := 'SP-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(extensions.gen_random_uuid()::text, 1, 8);
  INSERT INTO public.sealed_product_orders (
    order_no, user_id, sealed_product_id, quantity, unit_price, total_amount,
    shipping_fee, platform_fee, is_pre_order, estimated_ship_date,
    buyer_address, status, payment_status
  ) VALUES (
    v_order_no_val, p_user_id, p_product_id, p_quantity, v_product_rec.listing_price, v_total_amount,
    v_product_rec.shipping_fee, ROUND(v_total_amount * v_product_rec.platform_fee_pct / 100, 2),
    v_product_rec.is_pre_order, v_product_rec.shipping_date,
    p_buyer_address, 'pending', 'unpaid'
  ) RETURNING id, order_no INTO v_order_id, v_order_no_val;
  UPDATE public.sealed_products SET reserved_quantity = reserved_quantity + p_quantity, updated_at = now()
  WHERE id = p_product_id;
  RETURN QUERY SELECT true, v_order_id, v_order_no_val, v_total_amount, 'Order created'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION create_sealed_product_order() IS '用户下单购买一级市场商品(盲盒) — 锁定价格, 冻结库存';

-- ============================================================
-- Part 15: RPC — cancel_sealed_product_order()
-- 取消一级市场订单 → 释放库存
-- NOTE: public.前缀(search_path='')
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_sealed_product_order(
  p_order_id UUID, p_user_id UUID, p_reason TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT)
AS $func$
DECLARE v_order_rec RECORD;
BEGIN
  SELECT * INTO v_order_rec FROM public.sealed_product_orders WHERE id = p_order_id AND user_id = p_user_id;
  IF v_order_rec IS NULL THEN
    RETURN QUERY SELECT false, 'Order not found'::TEXT; RETURN;
  END IF;
  IF v_order_rec.status NOT IN ('pending', 'confirmed') THEN
    RETURN QUERY SELECT false, 'Cannot cancel'::TEXT; RETURN;
  END IF;
  UPDATE public.sealed_product_orders SET status = 'cancelled', cancelled_at = now(), updated_at = now()
  WHERE id = p_order_id;
  UPDATE public.sealed_products SET reserved_quantity = reserved_quantity - v_order_rec.quantity, updated_at = now()
  WHERE id = v_order_rec.sealed_product_id;
  RETURN QUERY SELECT true, 'Cancelled, stock released'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION cancel_sealed_product_order() IS '取消一级市场订单 → 释放预留库存';

-- ============================================================
-- Part 16: RPC — admin_confirm_sealed_order()
-- 管理员操作一级市场订单(confirm/ship/deliver)
-- NOTE: public.前缀(search_path=''), 所有参数有默认值(42P13合规)
-- ============================================================
CREATE OR REPLACE FUNCTION admin_confirm_sealed_order(
  p_admin_id UUID, p_order_id UUID DEFAULT NULL,
  p_tracking_no TEXT DEFAULT NULL, p_shipping_carrier TEXT DEFAULT NULL,
  p_action TEXT DEFAULT 'confirm'
)
RETURNS TABLE(success BOOLEAN, message TEXT)
AS $func$
DECLARE v_admin_status TEXT; v_order_rec RECORD;
BEGIN
  SELECT status INTO v_admin_status FROM public.admins WHERE id = p_admin_id;
  IF v_admin_status IS NULL OR v_admin_status != 'active' THEN
    RETURN QUERY SELECT false, 'Admin not authorized'::TEXT; RETURN;
  END IF;
  SELECT * INTO v_order_rec FROM public.sealed_product_orders WHERE id = p_order_id;
  IF v_order_rec IS NULL THEN
    RETURN QUERY SELECT false, 'Order not found'::TEXT; RETURN;
  END IF;
  CASE p_action
    WHEN 'confirm' THEN
      IF v_order_rec.status != 'pending' THEN RETURN QUERY SELECT false, 'Must be pending'::TEXT; RETURN; END IF;
      UPDATE public.sealed_product_orders SET status = 'confirmed', updated_at = now() WHERE id = p_order_id;
    WHEN 'ship' THEN
      IF v_order_rec.status NOT IN ('confirmed', 'paid') THEN RETURN QUERY SELECT false, 'Must be confirmed/paid'::TEXT; RETURN; END IF;
      UPDATE public.sealed_product_orders SET status = 'shipping',
        tracking_no = COALESCE(p_tracking_no, public.sealed_product_orders.tracking_no),
        shipping_carrier = COALESCE(p_shipping_carrier, public.sealed_product_orders.shipping_carrier),
        shipped_at = now(), updated_at = now() WHERE id = p_order_id;
      UPDATE public.sealed_products SET sold_quantity = sold_quantity + v_order_rec.quantity,
        reserved_quantity = reserved_quantity - v_order_rec.quantity, updated_at = now()
      WHERE id = v_order_rec.sealed_product_id;
    WHEN 'deliver' THEN
      IF v_order_rec.status != 'shipping' THEN RETURN QUERY SELECT false, 'Must be shipping'::TEXT; RETURN; END IF;
      UPDATE public.sealed_product_orders SET status = 'delivered', delivered_at = now(), updated_at = now() WHERE id = p_order_id;
    ELSE RETURN QUERY SELECT false, 'Invalid action'::TEXT; RETURN;
  END CASE;
  RETURN QUERY SELECT true, 'Order ' || p_action || 'ed'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION admin_confirm_sealed_order() IS '管理员操作一级市场订单(confirm/ship/deliver)';

-- ============================================================
-- Part 17: RPC — admin_create_merchandise()
-- 管理员创建周边商品
-- NOTE: #variable_conflict use_column 解决 RETURNS TABLE sku 与表列歧义
-- ============================================================
CREATE OR REPLACE FUNCTION admin_create_merchandise(
  p_admin_id UUID, p_name TEXT DEFAULT 'New Merch',
  p_merch_type TEXT DEFAULT 'accessories', p_sku TEXT DEFAULT 'SKU-MC-TEMP',
  p_listing_price NUMERIC DEFAULT 50.00,
  p_name_en TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL,
  p_images TEXT[] DEFAULT NULL, p_thumbnail_url TEXT DEFAULT NULL,
  p_material TEXT DEFAULT NULL, p_color TEXT DEFAULT NULL, p_size TEXT DEFAULT NULL,
  p_weight_grams INTEGER DEFAULT NULL, p_cost_price NUMERIC DEFAULT 0,
  p_original_price NUMERIC DEFAULT NULL, p_member_price NUMERIC DEFAULT NULL,
  p_stock_quantity INTEGER DEFAULT 0, p_shipping_fee NUMERIC DEFAULT 0,
  p_platform_fee_pct NUMERIC DEFAULT 0, p_tags TEXT[] DEFAULT NULL,
  p_brand TEXT DEFAULT NULL, p_related_card_series TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, merchandise_id UUID, sku TEXT, message TEXT)
AS $func$
#variable_conflict use_column
DECLARE v_admin_status TEXT; v_merch_id UUID; v_sku TEXT;
BEGIN
  SELECT status INTO v_admin_status FROM public.admins WHERE id = p_admin_id;
  IF v_admin_status IS NULL OR v_admin_status != 'active' THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 'Admin not authorized'::TEXT; RETURN;
  END IF;
  INSERT INTO public.merchandise (
    admin_id, name, name_en, merch_type, sku, description, images, thumbnail_url,
    material, color, size, weight_grams,
    cost_price, listing_price, original_price, member_price,
    stock_quantity, shipping_fee, platform_fee_pct, tags, brand, related_card_series, status
  ) VALUES (
    p_admin_id, p_name, p_name_en, p_merch_type, p_sku, p_description, p_images, p_thumbnail_url,
    p_material, p_color, p_size, p_weight_grams,
    p_cost_price, p_listing_price, p_original_price, p_member_price,
    p_stock_quantity, p_shipping_fee, p_platform_fee_pct, p_tags, p_brand, p_related_card_series,
    'draft'
  ) RETURNING id, sku INTO v_merch_id, v_sku;
  INSERT INTO public.platform_issue_logs (admin_id, action, target_type, target_id, details)
  VALUES (p_admin_id, 'create_merchandise', 'merchandise', v_merch_id,
    jsonb_build_object('name', p_name, 'sku', v_sku, 'merch_type', p_merch_type));
  RETURN QUERY SELECT true, v_merch_id, v_sku, 'Merchandise created'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION admin_create_merchandise() IS '管理员创建周边商品(卡套/卡垫等) — 完全手动, 无AI';

-- ============================================================
-- Part 18: RPC — admin_update_merchandise()
-- NOTE: public.前缀(search_path=''), 所有参数有默认值(42P13合规)
-- ============================================================
CREATE OR REPLACE FUNCTION admin_update_merchandise(
  p_admin_id UUID, p_merchandise_id UUID DEFAULT NULL,
  p_name TEXT DEFAULT NULL, p_merch_type TEXT DEFAULT NULL,
  p_sku TEXT DEFAULT NULL, p_description TEXT DEFAULT NULL,
  p_images TEXT[] DEFAULT NULL, p_thumbnail_url TEXT DEFAULT NULL,
  p_material TEXT DEFAULT NULL, p_color TEXT DEFAULT NULL, p_size TEXT DEFAULT NULL,
  p_cost_price NUMERIC DEFAULT NULL, p_listing_price NUMERIC DEFAULT NULL,
  p_original_price NUMERIC DEFAULT NULL, p_member_price NUMERIC DEFAULT NULL,
  p_stock_quantity INTEGER DEFAULT NULL, p_shipping_fee NUMERIC DEFAULT NULL,
  p_status TEXT DEFAULT NULL, p_tags TEXT[] DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, message TEXT)
AS $func$
DECLARE v_admin_status TEXT;
BEGIN
  SELECT status INTO v_admin_status FROM public.admins WHERE id = p_admin_id;
  IF v_admin_status IS NULL OR v_admin_status != 'active' THEN
    RETURN QUERY SELECT false, 'Admin not authorized'::TEXT; RETURN;
  END IF;
  UPDATE public.merchandise SET
    name = COALESCE(p_name, public.merchandise.name),
    merch_type = COALESCE(p_merch_type, public.merchandise.merch_type),
    sku = COALESCE(p_sku, public.merchandise.sku),
    description = COALESCE(p_description, public.merchandise.description),
    images = COALESCE(p_images, public.merchandise.images),
    thumbnail_url = COALESCE(p_thumbnail_url, public.merchandise.thumbnail_url),
    material = COALESCE(p_material, public.merchandise.material),
    color = COALESCE(p_color, public.merchandise.color),
    size = COALESCE(p_size, public.merchandise.size),
    cost_price = COALESCE(p_cost_price, public.merchandise.cost_price),
    listing_price = COALESCE(p_listing_price, public.merchandise.listing_price),
    original_price = COALESCE(p_original_price, public.merchandise.original_price),
    member_price = COALESCE(p_member_price, public.merchandise.member_price),
    stock_quantity = COALESCE(p_stock_quantity, public.merchandise.stock_quantity),
    shipping_fee = COALESCE(p_shipping_fee, public.merchandise.shipping_fee),
    status = COALESCE(p_status, public.merchandise.status),
    tags = COALESCE(p_tags, public.merchandise.tags),
    updated_at = now()
  WHERE id = p_merchandise_id;
  IF NOT FOUND THEN RETURN QUERY SELECT false, 'Merchandise not found'::TEXT; RETURN; END IF;
  RETURN QUERY SELECT true, 'Merchandise updated'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION admin_update_merchandise() IS '管理员更新周边商品信息';

-- ============================================================
-- Part 19: RPC — create_merchandise_order()
-- 用户下单购买周边商品
-- NOTE: #variable_conflict use_column 解决 RETURNS TABLE order_no 与表列歧义
-- ============================================================
CREATE OR REPLACE FUNCTION create_merchandise_order(
  p_user_id UUID, p_merchandise_id UUID, p_quantity INTEGER DEFAULT 1,
  p_selected_color TEXT DEFAULT NULL, p_selected_size TEXT DEFAULT NULL,
  p_buyer_address JSONB DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, order_id UUID, order_no TEXT, total_amount NUMERIC, message TEXT)
AS $func$
#variable_conflict use_column
DECLARE
  v_merch_rec RECORD; v_order_no_val TEXT; v_order_id UUID;
  v_total_amount NUMERIC(10,2); v_available INTEGER;
BEGIN
  SELECT * INTO v_merch_rec FROM public.merchandise WHERE id = p_merchandise_id;
  IF v_merch_rec IS NULL THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Merchandise not found'::TEXT; RETURN;
  END IF;
  IF v_merch_rec.status NOT IN ('active', 'on_sale') THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Not available'::TEXT; RETURN;
  END IF;
  v_available := v_merch_rec.stock_quantity - v_merch_rec.reserved_quantity - v_merch_rec.sold_quantity;
  IF v_available < p_quantity THEN
    RETURN QUERY SELECT false, NULL::UUID, ''::TEXT, 0::NUMERIC, 'Insufficient stock'::TEXT; RETURN;
  END IF;
  v_total_amount := v_merch_rec.listing_price * p_quantity + v_merch_rec.shipping_fee;
  v_order_no_val := 'MC-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(extensions.gen_random_uuid()::text, 1, 8);
  INSERT INTO public.merchandise_orders (
    order_no, user_id, merchandise_id, quantity, unit_price, total_amount,
    shipping_fee, platform_fee, selected_color, selected_size, buyer_address,
    status, payment_status
  ) VALUES (
    v_order_no_val, p_user_id, p_merchandise_id, p_quantity, v_merch_rec.listing_price, v_total_amount,
    v_merch_rec.shipping_fee, ROUND(v_total_amount * v_merch_rec.platform_fee_pct / 100, 2),
    p_selected_color, p_selected_size, p_buyer_address, 'pending', 'unpaid'
  ) RETURNING id, order_no INTO v_order_id, v_order_no_val;
  UPDATE public.merchandise SET reserved_quantity = reserved_quantity + p_quantity, updated_at = now()
  WHERE id = p_merchandise_id;
  RETURN QUERY SELECT true, v_order_id, v_order_no_val, v_total_amount, 'Merchandise order created'::TEXT;
END;
$func$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION create_merchandise_order() IS '用户下单购买周边商品';

-- ============================================================
-- Part 20.5: 扩展 platform_issue_logs CHECK 约束
-- 添加三层市场体系新的 action 和 target_type 值
-- ============================================================

ALTER TABLE public.platform_issue_logs
  DROP CONSTRAINT platform_issue_logs_action_check,
  DROP CONSTRAINT platform_issue_logs_target_type_check;

ALTER TABLE public.platform_issue_logs
  ADD CONSTRAINT platform_issue_logs_action_check
  CHECK (action IN (
    'publish_card', 'update_card', 'cancel_pre_order', 'confirm_pre_order',
    'adjust_stock', 'login', 'logout',
    'create_sealed_product', 'update_sealed_product', 'delete_sealed_product',
    'confirm_sealed_order', 'ship_sealed_order', 'deliver_sealed_order',
    'create_merchandise', 'update_merchandise', 'delete_merchandise',
    'confirm_merchandise_order', 'ship_merchandise_order', 'deliver_merchandise_order'
  ));

ALTER TABLE public.platform_issue_logs
  ADD CONSTRAINT platform_issue_logs_target_type_check
  CHECK (target_type IN (
    'platform_card', 'pre_order', 'admin', 'system',
    'sealed_product', 'sealed_product_order',
    'merchandise', 'merchandise_order'
  ));

-- ============================================================
-- Part 20: AI识卡规则 — 触发器强制限制AI识卡仅用于二级市场
-- ============================================================

-- ai_scan_logs 添加 market_tier 字段强制为 secondary
ALTER TABLE ai_scan_logs ADD COLUMN IF NOT EXISTS market_tier TEXT NOT NULL DEFAULT 'secondary'
  CHECK (market_tier = 'secondary');

-- scan_history 同样添加
ALTER TABLE scan_history ADD COLUMN IF NOT EXISTS market_tier TEXT NOT NULL DEFAULT 'secondary'
  CHECK (market_tier = 'secondary');

COMMENT ON COLUMN ai_scan_logs.market_tier IS 'AI识卡仅用于二级市场(已拆卡录入)';
COMMENT ON COLUMN scan_history.market_tier IS 'AI识卡仅用于二级市场(已拆卡录入)';

-- ============================================================
-- Part 21: 清理旧的双履约/直播/商家字段
-- ============================================================

-- consignments: 移除直播相关字段(直播间不管理库存)
ALTER TABLE consignments DROP COLUMN IF EXISTS live_session_id;
ALTER TABLE consignments DROP COLUMN IF EXISTS sale_source;

-- products: 移除平台自营和商家字段
ALTER TABLE products DROP COLUMN IF EXISTS is_platform_product;
ALTER TABLE products DROP COLUMN IF EXISTS seller_id;

-- profiles: 移除商家认证字段(简化为 admin/user)
ALTER TABLE profiles DROP COLUMN IF EXISTS merchant_name;
ALTER TABLE profiles DROP COLUMN IF EXISTS merchant_badge;
ALTER TABLE profiles DROP COLUMN IF EXISTS merchant_verified_at;
ALTER TABLE profiles DROP COLUMN IF EXISTS merchant_desc;
ALTER TABLE profiles DROP COLUMN IF EXISTS merchant_sort_weight;

-- 移除旧的直播相关表(空数据)
DROP TABLE IF EXISTS live_sync_items CASCADE;
DROP TABLE IF EXISTS live_sessions CASCADE;
DROP VIEW IF EXISTS live_sessions_overview CASCADE;

-- 移除商家相关视图
DROP VIEW IF EXISTS market_list_with_seller CASCADE;

-- 移除自营标记触发器
DROP TRIGGER IF EXISTS trg_mark_platform_sale ON consignments;
DROP FUNCTION IF EXISTS trg_mark_platform_sale_func() CASCADE;

-- 移除商家管理 RPC
DROP FUNCTION IF EXISTS admin_verify_merchant(UUID);
DROP FUNCTION IF EXISTS admin_revoke_merchant(UUID);
DROP FUNCTION IF EXISTS sync_card_to_live(UUID, UUID, NUMERIC);
DROP FUNCTION IF EXISTS admin_start_live_session(UUID, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS admin_end_live_session(UUID, UUID);

-- 移除旧的 TikTok Shop 相关内容(0034 前一版, 已被本版替换)
-- 如果之前已执行则忽略, 未执行则不存在
DROP TABLE IF EXISTS tiktok_shop_config CASCADE;
DROP TABLE IF EXISTS tiktok_shop_products CASCADE;
DROP TABLE IF EXISTS sync_logs CASCADE;
DROP TABLE IF EXISTS price_push_queue CASCADE;
DROP TABLE IF EXISTS live_selection_suggestions CASCADE;
DROP FUNCTION IF EXISTS sync_card_to_tiktok_shop(UUID, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS push_price_update_to_tiktok(TEXT, INTEGER, BOOLEAN);
DROP FUNCTION IF EXISTS generate_live_selection(TEXT, INTEGER, NUMERIC);
DROP FUNCTION IF EXISTS batch_sync_platform_cards(TEXT, UUID[], INTEGER);
DROP FUNCTION IF EXISTS update_tiktok_product_status(UUID, TEXT, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS mark_tiktok_product_delisted(UUID, TEXT);
DROP FUNCTION IF EXISTS get_sync_logs(TEXT, TEXT, TEXT, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS get_price_push_queue_status(TEXT, TEXT);
DROP FUNCTION IF EXISTS accept_reject_live_selection(UUID, TEXT);
DROP FUNCTION IF EXISTS cleanup_expired_selections(TEXT, INTEGER);
DROP FUNCTION IF EXISTS trg_enqueue_price_push_dedup() CASCADE;
DROP VIEW IF EXISTS tiktok_sync_status_view CASCADE;
DROP VIEW IF EXISTS live_selection_candidates CASCADE;

-- 移除 card_market 的 tiktok 相关字段(如果之前添加了)
ALTER TABLE card_market DROP COLUMN IF EXISTS tiktok_synced;
ALTER TABLE card_market DROP COLUMN IF EXISTS tiktok_product_id;
ALTER TABLE card_market DROP COLUMN IF EXISTS last_tiktok_sync_at;

-- ============================================================
-- Part 22: platform_store_list 视图更新
-- ============================================================
CREATE OR REPLACE VIEW platform_store_list AS
SELECT
  pc.id,
  pc.name,
  pc.name_en,
  pc.set_name,
  pc.card_image_url,
  pc.thumbnail_url,
  pc.description,
  pc.card_category,
  pc.rarity,
  pc.condition,
  pc.listing_price,
  pc.mark_price,
  cm.final_price,
  cm.price_source,
  pc.stock_quantity,
  pc.reserved_quantity,
  pc.sold_quantity,
  pc.available_quantity,
  pc.status,
  pc.shipping_fee,
  pc.platform_fee_pct,
  pc.created_at,
  cm.source_type,
  cm.activity_score,
  cm.market_state
FROM platform_cards pc
LEFT JOIN card_market cm ON cm.id = pc.card_market_id
WHERE pc.status IN ('active', 'on_sale')
ORDER BY pc.created_at DESC;

COMMENT ON VIEW platform_store_list IS '二级市场官方卡牌商店 — 已确认单卡资产';

-- ============================================================
-- Part 23: consignments 添加 market_tier 标记
-- ============================================================
ALTER TABLE consignments ADD COLUMN IF NOT EXISTS market_tier TEXT NOT NULL DEFAULT 'secondary'
  CHECK (market_tier = 'secondary');

COMMENT ON COLUMN consignments.market_tier IS '寄售仅用于二级市场(已拆卡交易)';

-- ============================================================
-- Part 24: 防止一级市场商品进入二级市场的约束
-- ============================================================

-- consignments 不允许 platform 来源(平台不自建二级市场库存)
-- 但允许 is_platform_sale = true 表示平台官方卡牌上架
ALTER TABLE consignments ADD CONSTRAINT chk_consignment_market_tier
  CHECK (market_tier = 'secondary');

-- 一级市场商品不允许关联 card_market(不使用mark_price)
-- sealed_products 无 card_market_id 外键, 无 mark_price 字段

-- 周边商品不允许关联 card_market
-- merchandise 无 card_market_id 外键, 无 mark_price 字段

-- ============================================================
-- Part 25: RLS 策略
-- ============================================================

-- sealed_products: 公开读取, 管理员写入
ALTER TABLE sealed_products ENABLE ROW LEVEL SECURITY;
CREATE POLICY read_sealed_products ON sealed_products FOR SELECT USING (true);
CREATE POLICY write_sealed_products_rpc ON sealed_products FOR ALL USING (true) WITH CHECK (true);

-- sealed_product_orders: 用户可查看自己的, 管理员可查看所有
ALTER TABLE sealed_product_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY read_own_sealed_orders ON sealed_product_orders FOR SELECT
  USING (user_id = auth.uid() OR EXISTS (SELECT 1 FROM admins WHERE status = 'active'));
CREATE POLICY write_sealed_orders_rpc ON sealed_product_orders FOR ALL USING (true) WITH CHECK (true);

-- merchandise: 公开读取, 管理员写入
ALTER TABLE merchandise ENABLE ROW LEVEL SECURITY;
CREATE POLICY read_merchandise ON merchandise FOR SELECT USING (true);
CREATE POLICY write_merchandise_rpc ON merchandise FOR ALL USING (true) WITH CHECK (true);

-- merchandise_orders: 用户可查看自己的, 管理员可查看所有
ALTER TABLE merchandise_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY read_own_merch_orders ON merchandise_orders FOR SELECT
  USING (user_id = auth.uid() OR EXISTS (SELECT 1 FROM admins WHERE status = 'active'));
CREATE POLICY write_merch_orders_rpc ON merchandise_orders FOR ALL USING (true) WITH CHECK (true);

-- ============================================================
-- Part 26: 索引优化
-- ============================================================

-- sealed_products: 按类型+状态+品牌查询
CREATE INDEX IF NOT EXISTS idx_sp_type_status ON sealed_products (product_type, status);
CREATE INDEX IF NOT EXISTS idx_sp_brand_series ON sealed_products (brand, series_name);
CREATE INDEX IF NOT EXISTS idx_sp_sku ON sealed_products (sku);
CREATE INDEX IF NOT EXISTS idx_sp_pre_order ON sealed_products (is_pre_order, status) WHERE is_pre_order = true;

-- sealed_product_orders: 按用户+状态查询
CREATE INDEX IF NOT EXISTS idx_spo_user_status ON sealed_product_orders (user_id, status);
CREATE INDEX IF NOT EXISTS idx_spo_product ON sealed_product_orders (sealed_product_id, status);
CREATE INDEX IF NOT EXISTS idx_spo_order_no ON sealed_product_orders (order_no);

-- merchandise: 按类型+状态
CREATE INDEX IF NOT EXISTS idx_m_type_status ON merchandise (merch_type, status);
CREATE INDEX IF NOT EXISTS idx_m_sku ON merchandise (sku);

-- merchandise_orders: 按用户+状态
CREATE INDEX IF NOT EXISTS idx_mo_user_status ON merchandise_orders (user_id, status);
CREATE INDEX IF NOT EXISTS idx_mo_product ON merchandise_orders (merchandise_id, status);

-- ============================================================
-- Part 27: 刷新 platform_cards available_quantity 生成列
-- (如果之前不存在则添加)
-- ============================================================
-- platform_cards 的 available_quantity 已在 0033 中创建为生成列
-- 无需重复操作

-- ============================================================
-- Part 28: 系统强制约束声明
-- ============================================================

-- 一级市场: 无 AI 识卡, 管理员定价, SKU 管理
COMMENT ON TABLE sealed_products IS '一级市场商品 — 盲盒/未拆封. 禁止AI识卡. 价格由管理员设定(listing_price). 支持SKU+库存+预售';

-- 二级市场: AI 识卡, mark_price 定价, 市场交易
COMMENT ON TABLE card_market IS '二级市场价格表 — 仅用于已拆卡/单卡. AI识卡录入. mark_price动态定价. 禁止盲盒定价';
COMMENT ON TABLE user_collections IS '二级市场用户资产 — 仅用于拆盒后的卡牌收藏. 禁止盲盒录入';

-- 周边商品: 完全手动, 标准电商
COMMENT ON TABLE merchandise IS '周边商品 — 卡套/卡垫等. 完全手动录入. 不使用AI识卡. 标准电商逻辑';

-- ============================================================
-- 完成 0034 迁移
-- 分层卡牌经济系统:
--   一级市场(盲盒) → 不确定性商品 → 管理员定价 → sealed_products
--   二级市场(卡牌) → 确定性资产   → AI识卡+mark_price → card_market
--   周边商品(配件) → 标准电商     → 手动录入 → merchandise
-- ============================================================
