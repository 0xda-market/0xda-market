-- Replace the nine-month Telegram Premium product without losing its catalog
-- position or any append-only price history that references the old SKU.
DO $$
DECLARE
  original_position integer;
  temporary_position integer;
BEGIN
  SELECT position
    INTO original_position
    FROM market.products
   WHERE sku = 'premium_9m'
   FOR UPDATE;

  IF original_position IS NULL THEN
    UPDATE market.products
       SET name = 'Telegram Premium 12 міс.',
           button_label = 'Premium 12 міс.',
           metadata = metadata || '{"duration_months":12}'::jsonb,
           updated_at = now(),
           version = version + 1
     WHERE sku = 'premium_12m';

    IF NOT FOUND THEN
      RAISE EXCEPTION 'neither premium_9m nor premium_12m exists';
    END IF;

    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM market.products WHERE sku = 'premium_12m') THEN
    RAISE EXCEPTION 'premium_9m and premium_12m both exist';
  END IF;

  SELECT COALESCE(MAX(position), -1) + 1
    INTO temporary_position
    FROM market.products;

  UPDATE market.products
     SET position = temporary_position
   WHERE sku = 'premium_9m';

  INSERT INTO market.products (
    sku,
    name,
    button_label,
    metadata,
    status,
    position,
    created_at,
    updated_at,
    version
  )
  SELECT
    'premium_12m',
    'Telegram Premium 12 міс.',
    'Premium 12 міс.',
    metadata || '{"duration_months":12}'::jsonb,
    status,
    original_position,
    created_at,
    now(),
    version + 1
  FROM market.products
  WHERE sku = 'premium_9m';

  UPDATE market.product_prices
     SET sku = 'premium_12m'
   WHERE sku = 'premium_9m';

  DELETE FROM market.products
   WHERE sku = 'premium_9m';
END
$$;
