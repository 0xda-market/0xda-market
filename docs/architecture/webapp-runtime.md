# WebApp runtime architecture

The browser surface follows one dependency direction:

```text
channel host -> reusable browser application -> core JSON APIs
```

[webapp-core](https://github.com/0xda-market/webapp-core) owns the browser-native catalog engine, immutable snapshot state, local search and pagination, checkout state machine and reusable role-driven UI.

A channel host owns host SDK integration, signed transport, HTML/CSS shell, BFF behavior and deployment entry points. It consumes an exact immutable `webapp-core` revision.

`core` owns only provider-agnostic domain and backend contracts. It does not package or serve browser modules or a standalone WebApp.

## Complete snapshot contract

`GET /v1/webapp/bootstrap` remains a core API and returns every active sellable product for one locale and presentation currency in a single response. Its `meta` contract includes `schema_version`, `snapshot_id`, `generated_at`, `count`, `available_count`, `complete: true`, `pagination: client`, `locale` and `currency`.

A market product is actionable only when the same live bootstrap observes both an applied client price and positive active broker liquidity. Broker supply alone intentionally keeps `price: null`; the administrator price workspace may apply only the changed price rows, after which the next bootstrap exposes the product without a core restart.

A product is buyer-available only when both conditions hold at snapshot generation time:

- an applied client price exists;
- at least one active broker listing has available inventory, a current FX-normalizable ask and positive required margin at the administrator sale price.

The applied client price is the administrator-controlled sale price. Broker asks never change it. Catalog availability checks profitability for quantity `1`; quote creation revalidates the same sale price against listings capable of fulfilling the complete requested quantity.

The snapshot emits `attributes.available` explicitly. A listed product whose current supply is not executable remains visible with its administrator price and `available: false`; an unlisted product omits the public price. Broker identity, individual supply prices, policy inputs and inventory allocation details remain private. Quote creation validates positive net margin again while locking current listing rows, so the snapshot is presentation state rather than settlement authority.

The public snapshot excludes internal audit identities. Browsing state is not settlement authority: quote, acceptance and order operations always revalidate current server state.

## Delivery contract

Core serves JSON APIs only. Browser assets are released from `webapp-core` and mounted by an external channel host. Production hosts must pin an immutable commit or released package version; default-branch URLs are not a supported dependency.
