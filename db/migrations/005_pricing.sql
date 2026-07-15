-- Prices are an append-only history, not a product attribute.
-- The current price of a product is the latest row for its sku;
-- "yesterday's price" is the latest row created before the start of the day.
-- Until a new application is submitted, the last applied prices remain in effect.
CREATE TABLE market.product_prices (
  id bigserial PRIMARY KEY,
  sku text NOT NULL REFERENCES market.products(sku),
  amount_usdt numeric(18, 6) NOT NULL CHECK (amount_usdt > 0),
  source text NOT NULL CHECK (source IN ('admin', 'core')),
  set_by_telegram_user_id text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX product_prices_sku_created_at_index
  ON market.product_prices(sku, created_at DESC, id DESC);

-- Localization: prices are stored in the base currency (USDT) and converted
-- to the user's currency at read time. usdt_per_unit is the real buy-side
-- rate: how many USDT we pay for one unit of the currency when acquiring
-- the product quantity.
CREATE TABLE market.fx_rates (
  currency text PRIMARY KEY CHECK (currency ~ '^[A-Z][A-Z0-9]{2,9}$'),
  usdt_per_unit numeric(18, 8) NOT NULL CHECK (usdt_per_unit > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO market.fx_rates (currency, usdt_per_unit) VALUES ('USDT', 1);
