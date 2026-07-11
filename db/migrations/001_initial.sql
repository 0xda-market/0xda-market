CREATE SCHEMA IF NOT EXISTS market;

CREATE TABLE market.intents (
  id text PRIMARY KEY,
  capability text NOT NULL,
  payload jsonb NOT NULL,
  context jsonb NOT NULL,
  created_at timestamptz NOT NULL,
  version bigint NOT NULL CHECK (version >= 0)
);

CREATE TABLE market.quotes (
  id text PRIMARY KEY,
  intent_id text NOT NULL REFERENCES market.intents(id),
  provider_key text NOT NULL,
  terms jsonb NOT NULL,
  private_state jsonb NOT NULL,
  expires_at timestamptz,
  created_at timestamptz NOT NULL,
  version bigint NOT NULL CHECK (version >= 0)
);

CREATE INDEX quotes_intent_id_index ON market.quotes(intent_id);

CREATE TABLE market.orders (
  id text PRIMARY KEY,
  intent_id text NOT NULL REFERENCES market.intents(id),
  quote_id text NOT NULL REFERENCES market.quotes(id),
  capability text NOT NULL,
  provider_key text NOT NULL,
  payload jsonb NOT NULL,
  context jsonb NOT NULL,
  terms jsonb NOT NULL,
  private_state jsonb NOT NULL,
  status text NOT NULL CHECK (
    status IN ('accepted', 'processing', 'pending', 'succeeded', 'failed', 'cancelled')
  ),
  attempts integer NOT NULL CHECK (attempts >= 0),
  progress jsonb,
  result jsonb,
  failure jsonb,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  version bigint NOT NULL CHECK (version >= 0)
);

CREATE INDEX orders_intent_id_index ON market.orders(intent_id);
CREATE UNIQUE INDEX orders_quote_id_index ON market.orders(quote_id);

CREATE TABLE market.manual_tasks (
  id text PRIMARY KEY,
  order_id text NOT NULL REFERENCES market.orders(id),
  capability text NOT NULL,
  payload jsonb NOT NULL,
  context jsonb NOT NULL,
  terms jsonb NOT NULL,
  status text NOT NULL CHECK (status IN ('pending', 'completed', 'rejected')),
  result jsonb,
  failure jsonb,
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  version bigint NOT NULL CHECK (version >= 0)
);

CREATE INDEX manual_tasks_status_created_at_index
  ON market.manual_tasks(status, created_at);
