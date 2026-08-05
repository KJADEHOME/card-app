-- TASK-CR-0104-F3: backfill profiles missing for existing Auth users.
-- This migration is insert-only and never changes an existing profile.

BEGIN;

DO $$
DECLARE
  v_missing_before bigint;
  v_inserted       bigint;
  v_missing_after  bigint;
BEGIN
  SELECT count(*)
    INTO v_missing_before
  FROM auth.users AS u
  LEFT JOIN public.profiles AS p ON p.id = u.id
  WHERE p.id IS NULL;

  WITH missing_users AS (
    SELECT
      u.id,
      lower(
        COALESCE(
          NULLIF(btrim(u.raw_user_meta_data ->> 'username'), ''),
          NULLIF(split_part(COALESCE(u.email, ''), '@', 1), ''),
          'user'
        )
      ) AS username_base,
      NULLIF(
        left(
          btrim(COALESCE(
            u.raw_user_meta_data ->> 'avatar_url',
            u.raw_user_meta_data ->> 'picture',
            ''
          )),
          2048
        ),
        ''
      ) AS avatar_url
    FROM auth.users AS u
    LEFT JOIN public.profiles AS p ON p.id = u.id
    WHERE p.id IS NULL
  ),
  normalized_users AS (
    SELECT
      id,
      COALESCE(
        NULLIF(btrim(regexp_replace(username_base, '[^a-z0-9_]+', '_', 'g'), '_'), ''),
        'user'
      ) AS username_base,
      avatar_url
    FROM missing_users
  ),
  inserted AS (
    INSERT INTO public.profiles (
      id,
      username,
      avatar_url,
      role
    )
    SELECT
      id,
      left(username_base, 32) || '_' || replace(id::text, '-', ''),
      avatar_url,
      'user'
    FROM normalized_users
    ON CONFLICT (id) DO NOTHING
    RETURNING id
  )
  SELECT count(*) INTO v_inserted FROM inserted;

  SELECT count(*)
    INTO v_missing_after
  FROM auth.users AS u
  LEFT JOIN public.profiles AS p ON p.id = u.id
  WHERE p.id IS NULL;

  RAISE NOTICE 'CR-0104-F3 missing profiles before: %', v_missing_before;
  RAISE NOTICE 'CR-0104-F3 profiles inserted: %', v_inserted;
  RAISE NOTICE 'CR-0104-F3 missing profiles after: %', v_missing_after;

  IF v_inserted <> v_missing_before OR v_missing_after <> 0 THEN
    RAISE EXCEPTION
      'CR-0104-F3 verification failed: before=%, inserted=%, after=%',
      v_missing_before,
      v_inserted,
      v_missing_after;
  END IF;
END;
$$;

COMMIT;
