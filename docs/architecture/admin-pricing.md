# Administrator pricing

Pricing remains a provider- and channel-neutral core capability. Command adapters, browser applications, websites and future clients must all use the same append-only price ledger and administrator authorization.

## Data model

`market.product_prices` is the authoritative append-only history. A row contains the catalog SKU, positive USDT amount, source, internal editor UUID and application time. Historical rows are never updated or deleted by the pricing API.

Price sources distinguish explicit administration from platform automation:

- `admin` — an administrator-owned application or override;
- `core` — an automatic market-owned price application;
- `fx:<provider>` — a provider-backed currency rate snapshot for non-marketable currency products.

The current product price is always the latest ledger row for that SKU regardless of source.

The monotonic pricing revision is the greatest persisted price-row ID. It represents the exact ledger state used to build an administrator proposal or automatic pricing decision.

## Proposal and administrator application

```text
GET /v1/admin/prices/proposal
  -> active products and currencies
  -> current and previous amounts
  -> meta.revision
  -> meta.generated_at

POST /v1/admin/prices
  revision: <proposal revision>
  prices: [one or more changed prices]
```

Every submitted price is validated against the catalog before persistence. The store then acquires one revision lock and compares the submitted revision with the current ledger revision.

- Memory uses one mutex-protected atomic append.
- PostgreSQL uses one transaction and transaction-scoped advisory lock.
- A stale revision raises `concurrency_conflict` before any price is appended.
- A valid application appends the submitted batch or nothing; unchanged and currently unpriced catalog rows need not be repeated.

An administrator remains allowed to set or lower a marketable product price. That write is authoritative immediately. Execution still revalidates profitability and can therefore reject broker supply that the new price cannot fund.

## Relationship to automatic pricing

Marketable products also participate in the automatic pricing contract described in [Automatic Pricing](automatic-pricing.md).

The automatic worker may:

1. create the first price after valid unit-executable broker supply appears;
2. raise the current price when it falls below the solvent competitive-reference floor;
3. leave an already-profitable price unchanged.

It never automatically lowers a profitable administrator or core price.

Broker asks therefore do not directly become buyer prices. The best valid normalized ask anchors a bounded market-owned routing reference; a more expensive competitor cannot raise the buyer price. The resulting reference is passed through the same profitability policy used during execution.

This preserves explicit administrator control without allowing an administrator override to bypass the execution loss-prevention gate. If an administrator deliberately sets a price below the current automatic floor, the next automatic pass may raise it again; disabling or changing that policy is an operational/configuration decision, not a browser-side capability.

## Concurrency

Administrator and automatic writes share one ledger revision contract.

Reviewed administrator workspaces submit the revision returned with their proposal. The automatic worker captures a revision before reading its price snapshot and applies changes against that captured revision. A concurrent admin/core/FX price append therefore invalidates a stale automatic batch instead of allowing it to overwrite newer intent.

Existing command adapters may omit the revision for backward compatibility. Reviewed interactive workspaces must preserve and submit the explicit proposal revision.

Every JSON API `POST` response includes a top-level operation `status`: `ok` for a successful response and `error` for a rejected response. Resource lifecycle status remains under `data.attributes.status`; the top-level field only reports the request outcome.

## History

`GET /v1/admin/prices/history` returns recent append-only rows ordered newest first, including source, editor and application time. Access requires the persisted internal administrator UUID. Channel-specific identities are resolved before the request reaches core.

Automatic `core` rows have no administrator editor UUID; provenance is carried by their source and timestamp.

## Boundaries

Pricing does not own channel copy, browser state, wallets or settlement. Currency exchange values use the same append-only price model because currencies are non-marketable catalog products whose amount means USDT paid per unit.

Automatic pricing never uses buyer-facing localized rounding as an economic input. Broker supply normalization, reference pricing and profitability remain in canonical USDT; localized smart rounding is presentation-only and upward-only.
