-- Products keep locale-neutral catalog state and the current price snapshot.
-- Localized user-facing copy lives in product_localizations, while
-- product_prices remains the append-only audit history.
ALTER TABLE market.products
  ADD COLUMN short_name text,
  ADD COLUMN current_price_id bigint,
  ADD COLUMN current_price_usdt numeric(18, 6)
    CHECK (current_price_usdt > 0),
  ADD COLUMN price_updated_at timestamptz,
  ADD COLUMN price_updated_by_user_id uuid
    REFERENCES market.users(id) ON DELETE SET NULL,
  ADD COLUMN updated_by_user_id uuid
    REFERENCES market.users(id) ON DELETE SET NULL;

UPDATE market.products
   SET short_name = CASE sku
     WHEN 'premium_3m' THEN 'Premium 3m'
     WHEN 'premium_6m' THEN 'Premium 6m'
     WHEN 'premium_12m' THEN 'Premium 12m'
     ELSE button_label
   END;

ALTER TABLE market.products
  ALTER COLUMN short_name SET NOT NULL,
  ADD CONSTRAINT products_short_name_length
    CHECK (length(short_name) BETWEEN 1 AND 64);

ALTER TABLE market.product_prices
  ADD COLUMN set_by_user_id uuid
    REFERENCES market.users(id) ON DELETE SET NULL;

-- Preserve audit ownership while moving new writes to the provider-independent
-- internal user UUID. The legacy Telegram ID stays readable for old rows.
UPDATE market.product_prices AS prices
   SET set_by_user_id = identities.user_id
  FROM market.user_identities AS identities
 WHERE identities.provider = 'telegram'
   AND identities.provider_user_id = prices.set_by_telegram_user_id
   AND prices.set_by_user_id IS NULL;

CREATE TABLE market.product_localizations (
  product_sku text NOT NULL
    REFERENCES market.products(sku) ON UPDATE CASCADE ON DELETE CASCADE,
  locale text NOT NULL DEFAULT 'en_US'
    CHECK (locale ~ '^[a-z]{2}_[A-Z]{2}$'),
  full_name text NOT NULL CHECK (length(full_name) BETWEEN 1 AND 160),
  button_label text NOT NULL CHECK (length(button_label) BETWEEN 1 AND 64),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by_user_id uuid REFERENCES market.users(id) ON DELETE SET NULL,
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0),
  PRIMARY KEY (product_sku, locale)
);

CREATE INDEX product_localizations_locale_index
  ON market.product_localizations(locale, product_sku);

-- The previous catalog copy was Ukrainian, so preserve it verbatim.
INSERT INTO market.product_localizations (
  product_sku,
  locale,
  full_name,
  button_label,
  created_at,
  updated_at
)
SELECT sku, 'uk_UA', name, button_label, created_at, updated_at
  FROM market.products;

-- en_US is the canonical fallback for every API consumer.
INSERT INTO market.product_localizations (
  product_sku,
  locale,
  full_name,
  button_label,
  created_at,
  updated_at
)
SELECT
  sku,
  'en_US',
  CASE sku
    WHEN 'premium_3m' THEN 'Telegram Premium 3 months'
    WHEN 'premium_6m' THEN 'Telegram Premium 6 months'
    WHEN 'premium_12m' THEN 'Telegram Premium 12 months'
    ELSE short_name
  END,
  short_name,
  created_at,
  updated_at
FROM market.products;

-- Backfill the current-price snapshot from the authoritative history.
WITH latest_prices AS (
  SELECT DISTINCT ON (sku)
    id,
    sku,
    amount_usdt,
    created_at,
    set_by_user_id
  FROM market.product_prices
  ORDER BY sku, created_at DESC, id DESC
)
UPDATE market.products AS products
   SET current_price_id = latest_prices.id,
       current_price_usdt = latest_prices.amount_usdt,
       price_updated_at = latest_prices.created_at,
       price_updated_by_user_id = latest_prices.set_by_user_id,
       updated_by_user_id = COALESCE(
         latest_prices.set_by_user_id,
         products.updated_by_user_id
       ),
       updated_at = GREATEST(products.updated_at, latest_prices.created_at),
       version = products.version + 1
  FROM latest_prices
 WHERE products.sku = latest_prices.sku;

CREATE FUNCTION market.sync_product_current_price()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE market.products
     SET current_price_id = NEW.id,
         current_price_usdt = NEW.amount_usdt,
         price_updated_at = NEW.created_at,
         price_updated_by_user_id = NEW.set_by_user_id,
         updated_by_user_id = COALESCE(NEW.set_by_user_id, updated_by_user_id),
         updated_at = GREATEST(updated_at, NEW.created_at),
         version = version + 1
   WHERE sku = NEW.sku
     AND (
       current_price_id IS NULL OR
       (NEW.created_at, NEW.id) >= (price_updated_at, current_price_id)
     );

  RETURN NEW;
END
$$;

CREATE TRIGGER product_prices_sync_current_price
AFTER INSERT ON market.product_prices
FOR EACH ROW
EXECUTE FUNCTION market.sync_product_current_price();

ALTER TABLE market.products
  DROP COLUMN name,
  DROP COLUMN button_label;
