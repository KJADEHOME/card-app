-- 0019_add_user_management_fields.sql
-- 用户管理功能增强

-- 1. 添加 is_disabled 字段到 profiles 表
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS is_disabled BOOLEAN DEFAULT false;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS disabled_reason TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS disabled_at TIMESTAMPTZ;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS disabled_by UUID REFERENCES auth.users(id);

-- 2. 添加禁用/启用用户的 RPC
CREATE OR REPLACE FUNCTION admin_disable_user(
    p_user_id UUID,
    p_reason TEXT DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- 检查操作者是否为管理员（简化版：检查 email）
    IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND email LIKE '%admin%') THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    UPDATE profiles 
    SET 
        is_disabled = true,
        disabled_reason = p_reason,
        disabled_at = NOW(),
        disabled_by = auth.uid()
    WHERE id = p_user_id;

    -- 可选：同时禁用 Supabase Auth（需要 Edge Function 调用 Admin API）

    RETURN TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION admin_enable_user(
    p_user_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- 检查操作者是否为管理员
    IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND email LIKE '%admin%') THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    UPDATE profiles 
    SET 
        is_disabled = false,
        disabled_reason = NULL,
        disabled_at = NULL,
        disabled_by = NULL
    WHERE id = p_user_id;

    RETURN TRUE;
END;
$$;

-- 3. 创建索引
CREATE INDEX IF NOT EXISTS idx_profiles_is_disabled ON profiles(is_disabled);

-- 4. 更新 RLS 策略（禁用用户无法登录）
-- 注意：真正的禁用需要在 Supabase Auth 层面，或通过 Edge Function 检查 is_disabled 字段

COMMENT ON COLUMN profiles.is_disabled IS '用户是否被禁用';
COMMENT ON COLUMN profiles.disabled_reason IS '禁用原因';
COMMENT ON COLUMN profiles.disabled_at IS '禁用时间';
COMMENT ON COLUMN profiles.disabled_by IS '禁用操作者';
