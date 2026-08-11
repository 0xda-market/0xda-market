# Purchase journey

A channel adapter turns a catalog selection into the existing provider-neutral lifecycle:

```text
product selection
  -> purchase intent
  -> expiring quote
  -> explicit acceptance
  -> order execution
  -> pending manual task
  -> succeeded or failed order
```

## Intent contract

The adapter creates a `manual.fulfillment` intent. The payload is an immutable snapshot of the selected catalog item and quoted USDT amount. Channel and authenticated client identifiers belong in `context`; core does not interpret channel-specific fields.

## Quote contract

Manual quotes expire after `MANUAL_QUOTE_TTL_SECONDS`, which defaults to 900 seconds. The adapter must show `expires_at` before acceptance and must not represent a selection as an accepted purchase.

Core remains authoritative: accepting an expired quote returns `quote_expired`.

## Execution contract

After explicit acceptance, the adapter accepts the quote and executes the order. Manual execution creates a durable operator task and normally returns an order in `pending` state. The client surface must state that fulfillment is in progress and retain a way to refresh the durable order after leaving the channel session.

A completed operator task resolves the same order to `succeeded`; a rejected task resolves through the existing structured failure contract. Repeated execution is idempotent and does not create duplicate tasks.

## Boundaries

- catalog grouping and presentation belong to channel adapters;
- quote expiry, acceptance and order transitions belong to core;
- operator matching and task persistence belong to the manual fulfillment adapter;
- channel-local state must not be required to recover an order.
