-- ============================================================
-- 0036: Production RLS Security Fixes
-- 修复上线前必须解决的CRITICAL安全问题
-- ============================================================

-- ==========================================
-- FIX 1: profiles RLS — 替换"Allow all"为用户只能操作自己数据
-- ==========================================
DROP POLICY IF EXISTS "Allow all" ON public.profiles;

CREATE POLICY "Users can view all profiles" ON public.profiles
  FOR SELECT USING (true);

CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can insert own profile" ON public.profiles
  FOR INSERT WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can delete own profile" ON public.profiles
  FOR DELETE USING (auth.uid() = id);

-- ==========================================
-- FIX 2: payment_orders — 替换危险update策略
-- ==========================================
DROP POLICY IF EXISTS "payment_orders_update_own" ON public.payment_orders;

CREATE POLICY "Users can update own payment orders" ON public.payment_orders
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ==========================================
-- FIX 3: sealed_products/sealed_product_orders — 写操作仅service_role
-- ==========================================
DROP POLICY IF EXISTS "write_sealed_products_rpc" ON public.sealed_products;

CREATE POLICY "sealed_products_write_service" ON public.sealed_products
  FOR ALL USING (CURRENT_USER = 'supabase_admin' OR CURRENT_USER ~ 'service_role');

DROP POLICY IF EXISTS "write_sealed_orders_rpc" ON public.sealed_product_orders;

CREATE POLICY "sealed_orders_write_service" ON public.sealed_product_orders
  FOR ALL USING (CURRENT_USER = 'supabase_admin' OR CURRENT_USER ~ 'service_role');

-- ==========================================
-- FIX 4: merchandise/merchandise_orders — 写操作仅service_role
-- ==========================================
DROP POLICY IF EXISTS "write_merchandise_rpc" ON public.merchandise;

CREATE POLICY "merchandise_write_service" ON public.merchandise
  FOR ALL USING (CURRENT_USER = 'supabase_admin' OR CURRENT_USER ~ 'service_role');

DROP POLICY IF EXISTS "write_merch_orders_rpc" ON public.merchandise_orders;

CREATE POLICY "merch_orders_write_service" ON public.merchandise_orders
  FOR ALL USING (CURRENT_USER = 'supabase_admin' OR CURRENT_USER ~ 'service_role');

-- ==========================================
-- FIX 5: system_flags — 启用RLS
-- ==========================================
ALTER TABLE public.system_flags ENABLE ROW LEVEL SECURITY;

-- ==========================================
-- FIX 6: user_collections — 删除重复RLS策略
-- ==========================================
DROP POLICY IF EXISTS "Users own their collections" ON public.user_collections;

-- ==========================================
-- FIX 7: card-images存储桶 — 设置大小和类型限制
-- ==========================================
UPDATE storage.buckets 
SET file_size_limit = 10485760,  -- 10MB
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
WHERE id = 'card-images';

-- ==========================================
-- Comments
-- ==========================================
COMMENT ON POLICY "Users can view all profiles" ON public.profiles IS 'Production fix: 所有用户可查看profile(市场需要)';
COMMENT ON POLICY "Users can update own profile" ON public.profiles IS 'Production fix: 仅能更新自己的profile,防止提权';
COMMENT ON POLICY "Users can insert own profile" ON public.profiles IS 'Production fix: 仅能创建自己的profile';
COMMENT ON POLICY "Users can delete own profile" ON public.profiles IS 'Production fix: 仅能删除自己的profile';
COMMENT ON POLICY "sealed_products_write_service" ON public.sealed_products IS 'Production fix: 写操作仅service_role(RPC用SECURITY DEFINER)';
COMMENT ON POLICY "merchandise_write_service" ON public.merchandise IS 'Production fix: 写操作仅service_role(RPC用SECURITY DEFINER)';
