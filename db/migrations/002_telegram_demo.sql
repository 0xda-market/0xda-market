ALTER TABLE market.manual_tasks
  ADD COLUMN claimed_by text;

ALTER TABLE market.manual_tasks
  DROP CONSTRAINT manual_tasks_status_check;

ALTER TABLE market.manual_tasks
  ADD CONSTRAINT manual_tasks_status_check CHECK (
    status IN ('pending', 'claimed', 'completed', 'rejected')
  );

ALTER TABLE market.manual_tasks
  ADD CONSTRAINT manual_tasks_claimed_by_check CHECK (
    status <> 'claimed' OR claimed_by IS NOT NULL
  );

CREATE TABLE market.telegram_brokers (
  chat_id text PRIMARY KEY,
  user_id text NOT NULL,
  username text,
  display_name text NOT NULL,
  status text NOT NULL CHECK (status IN ('ready', 'offline')),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL
);

CREATE INDEX telegram_brokers_status_updated_at_index
  ON market.telegram_brokers(status, updated_at);

CREATE TABLE market.telegram_demo_orders (
  task_id text PRIMARY KEY REFERENCES market.manual_tasks(id),
  order_id text NOT NULL UNIQUE REFERENCES market.orders(id),
  client_chat_id text NOT NULL,
  broker_chat_id text,
  status text NOT NULL CHECK (
    status IN ('broadcast', 'awaiting_payment', 'processing', 'completed')
  ),
  CHECK (
    (status = 'broadcast' AND broker_chat_id IS NULL) OR
    (status <> 'broadcast' AND broker_chat_id IS NOT NULL)
  ),
  created_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL,
  version bigint NOT NULL CHECK (version >= 0)
);

CREATE INDEX telegram_demo_orders_status_created_at_index
  ON market.telegram_demo_orders(status, created_at);

CREATE TABLE market.telegram_updates (
  bot_role text NOT NULL CHECK (bot_role IN ('client', 'broker')),
  update_id bigint NOT NULL,
  received_at timestamptz NOT NULL,
  PRIMARY KEY (bot_role, update_id)
);
