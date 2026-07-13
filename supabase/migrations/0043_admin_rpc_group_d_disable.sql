-- 0043_admin_rpc_group_d_disable.sql
-- SH-003C Phase 3 Group D: disable unreferenced legacy administrator RPCs.
-- Functions are retained for rollback/forensics; browser roles lose EXECUTE.
BEGIN;

DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public'
           AND p.proname IN (
               'admin_update_platform_card',
               'admin_confirm_pre_order',
               'admin_bulk_list_cards',
               'admin_create_sealed_product',
               'admin_update_sealed_product',
               'admin_confirm_sealed_order',
               'admin_create_merchandise',
               'admin_update_merchandise'
           )
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC', r.nspname,r.proname,r.args);
        EXECUTE format('REVOKE ALL ON FUNCTION %I.%I(%s) FROM anon', r.nspname,r.proname,r.args);
        EXECUTE format('REVOKE ALL ON FUNCTION %I.%I(%s) FROM authenticated', r.nspname,r.proname,r.args);
        EXECUTE format('COMMENT ON FUNCTION %I.%I(%s) IS %L', r.nspname,r.proname,r.args,
            'DEPRECATED/DISABLED SH-003C Phase 3: no verified caller; browser EXECUTE revoked.');
    END LOOP;
END $$;

COMMIT;
