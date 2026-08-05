-- TASK-CR-0104-F2: trusted auth.users -> profiles synchronization
-- Keeps migration 0048 fail-closed: clients receive no direct profiles INSERT.

BEGIN;

-- The trigger inserts no role column. New rows receive this server-owned default.
ALTER TABLE public.profiles
  ALTER COLUMN role SET DEFAULT 'user';

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_username_base TEXT;
  v_username      TEXT;
  v_avatar_url    TEXT;
BEGIN
  -- username/avatar_url are the only user-originated profile fields accepted.
  -- Sensitive fields always come from database defaults and later admin-only flows.
  v_username_base := lower(
    COALESCE(
      NULLIF(btrim(NEW.raw_user_meta_data ->> 'username'), ''),
      NULLIF(split_part(COALESCE(NEW.email, ''), '@', 1), ''),
      'user'
    )
  );
  v_username_base := regexp_replace(v_username_base, '[^a-z0-9_]+', '_', 'g');
  v_username_base := btrim(v_username_base, '_');
  IF v_username_base = '' THEN
    v_username_base := 'user';
  END IF;

  -- Full UUID suffix makes the generated UNIQUE username collision-safe.
  v_username := left(v_username_base, 32) || '_' || replace(NEW.id::text, '-', '');
  v_avatar_url := NULLIF(
    left(
      btrim(COALESCE(
        NEW.raw_user_meta_data ->> 'avatar_url',
        NEW.raw_user_meta_data ->> 'picture',
        ''
      )),
      2048
    ),
    ''
  );

  INSERT INTO public.profiles (
    id,
    username,
    avatar_url
  )
  VALUES (
    NEW.id,
    v_username,
    v_avatar_url
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM anon;
REVOKE ALL ON FUNCTION public.handle_new_user() FROM authenticated;

COMMENT ON FUNCTION public.handle_new_user() IS
  'CR-0104-F2: trusted Auth trigger initializer. Inserts only id, username and avatar_url; role and sensitive fields use server-owned defaults.';

DROP TRIGGER IF EXISTS trg_auth_profile_sync ON auth.users;
CREATE TRIGGER trg_auth_profile_sync
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

COMMENT ON TRIGGER trg_auth_profile_sync ON auth.users IS
  'CR-0104-F2: creates one safe public.profiles row after Auth user creation.';

-- Security assertions: 0048 direct-client INSERT must remain absent.
DO $$
BEGIN
  IF has_table_privilege('anon', 'public.profiles', 'INSERT') THEN
    RAISE EXCEPTION 'CR-0104-F2 aborted: anon unexpectedly has profiles INSERT';
  END IF;
  IF has_table_privilege('authenticated', 'public.profiles', 'INSERT') THEN
    RAISE EXCEPTION 'CR-0104-F2 aborted: authenticated unexpectedly has profiles INSERT';
  END IF;
END;
$$;

COMMIT;