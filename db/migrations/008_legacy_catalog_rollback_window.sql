-- Expand/contract safety for v0.1.0.
--
-- Migration 007 moved user-facing copy into product_localizations and removed
-- these two columns. Reintroduce a deprecated compatibility copy for one
-- release window so the previous production core can still read the catalog
-- during an application rollback. New code does not read these columns; the
-- localization table remains the source of truth.
ALTER TABLE market.products
  ADD COLUMN name text
    CHECK (name IS NULL OR length(name) BETWEEN 1 AND 160),
  ADD COLUMN button_label text
    CHECK (button_label IS NULL OR length(button_label) BETWEEN 1 AND 64);

WITH compatibility_copy AS (
  SELECT
    products.sku,
    COALESCE(uk.full_name, en.full_name, products.short_name) AS name,
    COALESCE(uk.button_label, en.button_label, products.short_name) AS button_label
  FROM market.products AS products
  LEFT JOIN market.product_localizations AS uk
    ON uk.product_sku = products.sku AND uk.locale = 'uk_UA'
  LEFT JOIN market.product_localizations AS en
    ON en.product_sku = products.sku AND en.locale = 'en_US'
)
UPDATE market.products AS products
   SET name = compatibility_copy.name,
       button_label = compatibility_copy.button_label
  FROM compatibility_copy
 WHERE compatibility_copy.sku = products.sku;

COMMENT ON COLUMN market.products.name IS
  'Deprecated v0.1 rollback copy; use market.product_localizations.full_name';
COMMENT ON COLUMN market.products.button_label IS
  'Deprecated v0.1 rollback copy; use market.product_localizations.button_label';
