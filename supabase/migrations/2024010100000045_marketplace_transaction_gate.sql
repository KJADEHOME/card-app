BEGIN;
DROP POLICY IF EXISTS "Buyers can create orders" ON public.orders;
DROP POLICY IF EXISTS "Buyers and sellers update orders" ON public.orders;
DROP POLICY IF EXISTS "Users own wallet" ON public.wallets;
DROP POLICY IF EXISTS "Users insert own transactions" ON public.wallet_transactions;
CREATE POLICY "Users read own wallet" ON public.wallets FOR SELECT USING (auth.uid()=user_id);

CREATE OR REPLACE FUNCTION public.create_marketplace_order(p_consignment_id UUID,p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_buyer UUID:=auth.uid(); v_item public.consignments%ROWTYPE; v_existing public.orders%ROWTYPE; v_order_id UUID; v_order_no TEXT; v_total NUMERIC(12,2); v_rate NUMERIC:=0.03; v_fee NUMERIC(12,2); v_seller NUMERIC(12,2);
BEGIN
 IF v_buyer IS NULL THEN RETURN jsonb_build_object('success',false,'error','Authentication required'); END IF;
 IF p_idempotency_key IS NOT NULL THEN SELECT * INTO v_existing FROM public.orders WHERE idempotency_key=p_idempotency_key AND buyer_id=v_buyer; IF v_existing.id IS NOT NULL THEN RETURN jsonb_build_object('success',true,'idempotent',true,'order_id',v_existing.id,'order_no',v_existing.order_no,'total_amount',v_existing.total_amount); END IF; END IF;
 SELECT * INTO v_item FROM public.consignments WHERE id=p_consignment_id FOR UPDATE;
 IF v_item.id IS NULL OR v_item.status!='active' THEN RETURN jsonb_build_object('success',false,'error','Listing unavailable'); END IF;
 IF v_item.seller_id=v_buyer THEN RETURN jsonb_build_object('success',false,'error','Cannot buy own listing'); END IF;
 IF v_item.asking_price<=0 OR COALESCE(v_item.quantity,1)<=0 THEN RETURN jsonb_build_object('success',false,'error','Invalid listing'); END IF;
 SELECT COALESCE(value::numeric,0.03) INTO v_rate FROM public.platform_config WHERE key='platform_fee_rate';
 v_total:=v_item.asking_price+COALESCE(v_item.shipping_fee,0); v_fee:=ROUND(v_total*COALESCE(v_rate,0.03),2); v_seller:=v_total-v_fee;
 v_order_no:='CR'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')||upper(substr(replace(gen_random_uuid()::text,'-',''),1,4));
 INSERT INTO public.orders(order_no,buyer_id,seller_id,consignment_id,item_price,shipping_fee,platform_fee,total_amount,seller_earnings,seller_amount,currency,status,idempotency_key) VALUES(v_order_no,v_buyer,v_item.seller_id,v_item.id,v_item.asking_price,COALESCE(v_item.shipping_fee,0),v_fee,v_total,v_seller,v_seller,'CNY','pending',p_idempotency_key) RETURNING id INTO v_order_id;
 UPDATE public.consignments SET status='reserved',updated_at=NOW() WHERE id=v_item.id;
 RETURN jsonb_build_object('success',true,'order_id',v_order_id,'order_no',v_order_no,'total_amount',v_total,'platform_fee',v_fee,'seller_amount',v_seller,'status','pending');
END; $$;

CREATE OR REPLACE FUNCTION public.cancel_marketplace_order(p_order_id UUID) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_order public.orders%ROWTYPE;
BEGIN
 SELECT * INTO v_order FROM public.orders WHERE id=p_order_id FOR UPDATE;
 IF v_order.id IS NULL OR v_order.buyer_id!=auth.uid() THEN RETURN jsonb_build_object('success',false,'error','Order unavailable'); END IF;
 IF v_order.status!='pending' THEN RETURN jsonb_build_object('success',false,'error','Order cannot be cancelled'); END IF;
 UPDATE public.orders SET status='cancelled',cancelled_at=NOW(),updated_at=NOW() WHERE id=p_order_id;
 UPDATE public.consignments SET status='active',updated_at=NOW() WHERE id=v_order.consignment_id AND status='reserved';
 RETURN jsonb_build_object('success',true);
END; $$;
REVOKE ALL ON FUNCTION public.create_marketplace_order(UUID,TEXT) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.create_marketplace_order(UUID,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.cancel_marketplace_order(UUID) FROM PUBLIC,anon; GRANT EXECUTE ON FUNCTION public.cancel_marketplace_order(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.purchase_consignment(UUID,UUID) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.purchase_consignment_safe(UUID,UUID,TEXT,TEXT) FROM PUBLIC,anon,authenticated;
COMMIT;
