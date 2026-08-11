# Market bootstrap reconciliation

`bin/market-bootstrap` reconciles the configured buyer-facing market product set to a declarative desired state. It is intended for development/test resets and repeatable environment setup, not as a second pricing system.

The command owns two pieces of mutable market state:

- administrator sale prices in USDT;
- one active broker listing per SKU for the selected broker, including quantity, ask price and quote currency.

The required SKU set is defined by the bootstrap reconciler's current product contract. Missing, duplicate, or additional SKU rows are rejected before any write. Provider- or channel-specific interpretation of those SKUs belongs outside this operational contract.

## Contract

Use `config/market-bootstrap.example.json` as the schema example. Its numeric values are illustrative only and are not recommended market prices.

Each product row contains:

- `sku` — stable product ID;
- `sale_price_usdt` — administrator-controlled buyer unit price;
- `supply.quantity` — broker inventory quantity;
- `supply.price_amount` — broker ask per unit;
- `supply.currency` — ask currency, normally `USDT`.

The reconciler reads current prices and the selected broker's active listings, then applies only the diff. An identical second run performs no price writes and no listing writes. Existing listings are updated with optimistic concurrency; absent listings are created. More than one active listing for the same broker and SKU is treated as ambiguous state and fails instead of guessing.

A partially completed run is recoverable: correct the underlying error and run the same manifest again. Already-converged rows are skipped.

## Usage

Set the PostgreSQL URL and the internal UUID of the broker/admin whose supply should be reconciled, then pass the manifest path:

```sh
DEPLOY_ENV=development \
DATABASE_URL='postgresql://...' \
MARKET_BOOTSTRAP_ACTOR_USER_ID='INTERNAL_USER_UUID' \
bundle exec ruby bin/market-bootstrap path/to/market.json
```

`MARKET_BOOTSTRAP_MANIFEST` may be used instead of the positional path.

The command refuses to run when `DEPLOY_ENV=production` unless `ALLOW_MARKET_BOOTSTRAP_PRODUCTION=1` is explicitly present. Production execution remains an operational change and should follow the production approval policy; the flag is only a technical guard bypass, not authorization.

## Why this is not a migration

Prices and broker inventory are operational state. Database migrations define schema and invariant reference data, but they should not repeatedly overwrite changing commercial values. Keeping desired environment state in an explicit manifest makes resets reproducible while preserving append-only price history and normal listing concurrency semantics.
