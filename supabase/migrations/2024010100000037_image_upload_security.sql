-- ============================================================
-- Migration 0037: Image Upload Security (SEC-004 Phase 3)
-- 
-- 目的: Storage 桶安全加固
--   1. card-images 桶: file_size_limit + allowed_mime_types
--   2. 上传策略: 仅认证用户 + 仅本人目录 + MIME白名单
--   3. 读取策略: 公开读取 (卡牌图片需要展示)
--   4. 删除策略: 仅本人 + service_role
-- 
-- 依赖: 无新表，仅修改 storage schema
-- 风险: 低 — 仅影响新上传，已有文件不变
-- ============================================================

-- ========== 1. 更新 card-images 桶配置 ==========

-- 设置桶: 公开读取 + 文件大小限制 + MIME白名单
UPDATE storage.buckets
SET 
  public = true,
  file_size_limit = 5242880,  -- 5MB (5 * 1024 * 1024)
  allowed_mime_types = ARRAY[
    'image/jpeg',
    'image/png',
    'image/webp'
  ]
WHERE id = 'card-images';

-- 如果桶不存在则创建
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
SELECT 
  'card-images',
  'card-images',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
WHERE NOT EXISTS (
  SELECT 1 FROM storage.buckets WHERE id = 'card-images'
);

-- ========== 2. 删除旧策略 (如果存在) ==========

DROP POLICY IF EXISTS "card-images upload policy" ON storage.objects;
DROP POLICY IF EXISTS "card-images read policy" ON storage.objects;
DROP POLICY IF EXISTS "card-images delete policy" ON storage.objects;
DROP POLICY IF EXISTS "Allow authenticated uploads to card-images" ON storage.objects;
DROP POLICY IF EXISTS "Allow public read of card-images" ON storage.objects;
DROP POLICY IF EXISTS "Allow owner delete card-images" ON storage.objects;

-- ========== 3. 创建新安全策略 ==========

-- 3.1 上传策略: 仅认证用户 + 仅本人目录 (uid/filename)
-- 路径格式: {user_id}/{filename} 或 {user_id}/{subdir}/{filename}
CREATE POLICY "card_images_upload_authenticated"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'card-images'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 3.2 读取策略: 公开读取 (卡牌图片需要公开展示)
CREATE POLICY "card_images_read_public"
  ON storage.objects
  FOR SELECT
  TO public
  USING (bucket_id = 'card-images');

-- 3.3 删除策略: 仅本人可删除自己的图片
CREATE POLICY "card_images_delete_owner"
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'card-images'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 3.4 更新策略: 仅本人可更新自己的图片 (如覆盖上传)
CREATE POLICY "card_images_update_owner"
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'card-images'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'card-images'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- ========== 4. 验证 ==========

-- 显示更新后的桶配置
SELECT id, public, file_size_limit, allowed_mime_types
FROM storage.buckets
WHERE id = 'card-images';

-- 显示新策略
SELECT tablename, policyname, cmd, roles
FROM pg_policies
WHERE tablename = 'objects'
  AND schemaname = 'storage'
  AND policyname LIKE 'card_images_%'
ORDER BY policyname;

-- ========== 完成 ==========
-- 预期输出:
--   bucket_id: card-images
--   public: true
--   file_size_limit: 5242880 (5MB)
--   allowed_mime_types: {image/jpeg, image/png, image/webp}
--   policies: 4 (upload/read/delete/update)
