-- CardRealm Beta P0: close direct client writes around payment and escrow.
-- All state transitions remain available through the hardened RPC layer.

DROP POLICY IF EXISTS "Buyers and sellers update orders" ON public.orders;
DROP POLICY IF EXISTS "Buyers can create orders" ON public.orders;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.orders FROM anon, authenticated;

DROP POLICY IF EXISTS "Users can update own payment orders" ON public.payment_orders;
DROP POLICY IF EXISTS payment_orders_insert_own ON public.payment_orders;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE public.payment_orders FROM anon, authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON TABLE public.escrow_records, public.escrow_transactions
  FROM anon, authenticated;

ALTER TABLE public.price_activity_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_activity_stats FORCE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.price_activity_stats FROM anon, authenticated;

GRANT SELECT ON TABLE public.orders TO authenticated;
GRANT SELECT ON TABLE public.payment_orders TO authenticated;
GRANT SELECT ON TABLE public.escrow_records TO authenticated;

GRANT ALL ON TABLE
  public.orders,
  public.payment_orders,
  public.escrow_records,
  public.escrow_transactions,
  public.price_activity_stats
TO service_role;

COMMENT ON TABLE public.payment_orders IS
  'Payment order state is internal-write-only; clients may read their own rows through RLS.';