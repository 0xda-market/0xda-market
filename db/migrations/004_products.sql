CREATE TABLE market.products (
  sku text PRIMARY KEY CHECK (sku ~ '^[a-z0-9][a-z0-9_-]{0,59}$'),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 160),
  button_label text NOT NULL CHECK (length(button_label) BETWEEN 1 AND 64),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'inactive')),
  position integer NOT NULL CHECK (position >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  version bigint NOT NULL DEFAULT 0 CHECK (version >= 0)
);

CREATE UNIQUE INDEX products_position_index
  ON market.products(position);

CREATE INDEX products_status_position_index
  ON market.products(status, position);

INSERT INTO market.products (
  sku,
  name,
  button_label,
  metadata,
  status,
  position
) VALUES
  (
    'premium_3m',
    'Telegram Premium 3 міс.',
    'Premium 3 міс.',
    '{"family":"telegram_premium","duration_months":3}'::jsonb,
    'active',
    1
  ),
  (
    'premium_6m',
    'Telegram Premium 6 міс.',
    'Premium 6 міс.',
    '{"family":"telegram_premium","duration_months":6}'::jsonb,
    'active',
    2
  ),
  (
    'premium_9m',
    'Telegram Premium 9 міс.',
    'Premium 9 міс.',
    '{"family":"telegram_premium","duration_months":9}'::jsonb,
    'active',
    3
  ),
  (
    'stars_500',
    'Stars 500',
    'Stars 500',
    '{"family":"telegram_stars","amount":500}'::jsonb,
    'active',
    4
  ),
  (
    'stars_1000',
    'Stars 1000',
    'Stars 1000',
    '{"family":"telegram_stars","amount":1000}'::jsonb,
    'active',
    5
  ),
  (
    'stars_3000',
    'Stars 3000',
    'Stars 3000',
    '{"family":"telegram_stars","amount":3000}'::jsonb,
    'active',
    6
  ),
  (
    'ton',
    'TON',
    'TON',
    '{"family":"crypto_asset","symbol":"TON"}'::jsonb,
    'active',
    7
  ),
  (
    'btc',
    'BTC',
    'BTC',
    '{"family":"crypto_asset","symbol":"BTC"}'::jsonb,
    'active',
    8
  ),
  (
    'eth',
    'ETH',
    'ETH',
    '{"family":"crypto_asset","symbol":"ETH"}'::jsonb,
    'active',
    9
  );
