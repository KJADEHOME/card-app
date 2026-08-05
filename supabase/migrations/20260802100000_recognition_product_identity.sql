-- Local-only migration: exact recognition and pricing identity.
-- Deploy only after review; no production data or secrets are included.

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS product_code TEXT,
  ADD COLUMN IF NOT EXISTS region TEXT NOT NULL DEFAULT 'UNKNOWN'
    CHECK (region IN ('JP', 'KR', 'CN', 'US', 'UNKNOWN')),
  ADD COLUMN IF NOT EXISTS edition TEXT NOT NULL DEFAULT 'Unknown',
  ADD COLUMN IF NOT EXISTS is_first_edition BOOLEAN NOT NULL DEFAULT false;

ALTER TABLE public.sealed_products
  ADD COLUMN IF NOT EXISTS region TEXT NOT NULL DEFAULT 'UNKNOWN'
    CHECK (region IN ('JP', 'KR', 'CN', 'US', 'UNKNOWN')),
  ADD COLUMN IF NOT EXISTS edition TEXT NOT NULL DEFAULT 'Unknown',
  ADD COLUMN IF NOT EXISTS is_first_edition BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS carton_multiplier INTEGER
    CHECK (carton_multiplier IS NULL OR carton_multiplier > 0);

ALTER TABLE public.card_market
  ADD COLUMN IF NOT EXISTS product_code TEXT,
  ADD COLUMN IF NOT EXISTS region TEXT NOT NULL DEFAULT 'UNKNOWN'
    CHECK (region IN ('JP', 'KR', 'CN', 'US', 'UNKNOWN')),
  ADD COLUMN IF NOT EXISTS edition TEXT NOT NULL DEFAULT 'Unknown',
  ADD COLUMN IF NOT EXISTS is_first_edition BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS packaging_type TEXT NOT NULL DEFAULT 'card'
    CHECK (packaging_type IN ('card', 'slab', 'box', 'carton'));

CREATE INDEX IF NOT EXISTS idx_products_recognition_identity
  ON public.products(product_code, region, edition);
CREATE INDEX IF NOT EXISTS idx_sealed_products_recognition_identity
  ON public.sealed_products(barcode, region, edition);
CREATE INDEX IF NOT EXISTS idx_card_market_recognition_identity
  ON public.card_market(product_code, region, edition);

COMMENT ON COLUMN public.card_market.product_code IS
  'Set code or exact catalog identifier used with region and edition for price lookup.';
