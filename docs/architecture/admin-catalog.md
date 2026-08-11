# Administrator catalog contract

The administrator catalog API exposes the complete product model without adding channel knowledge to core.

## Boundaries

- `market.products` owns locale-neutral state: SKU, short name, status, position, marketability, metadata and audit/version fields.
- `market.product_localizations` owns user-facing copy keyed by `(product_sku, locale)`.
- `market.product_prices` remains the separate append-only price history. Product editing never writes a price.
- A channel adapter validates its external session and supplies the resolved internal actor UUID.
- Core verifies that actor through `Identity::AdminService`; a browser-supplied role is never trusted.

## API

### Read the complete catalog

`GET /v1/admin/products?actor_user_id=<uuid>&locale=en_US`

The response includes active, inactive, marketable and non-marketable products. Each product carries its optimistic-concurrency `version` and every stored localization with its own independent version.

### Update locale-neutral product state

`PATCH /v1/admin/products/:sku`

```json
{
  "actor_user_id": "<uuid>",
  "version": 3,
  "attributes": {
    "short_name": "Subscription · 3m",
    "status": "active",
    "position": 1,
    "marketable": true,
    "metadata": {
      "family": "subscription",
      "duration_months": 3
    }
  }
}
```

Only supplied attributes change. The SKU, price snapshot and creation timestamp are immutable through this endpoint.

### Create or update a localization

`PUT /v1/admin/products/:sku/localizations/:locale`

```json
{
  "actor_user_id": "<uuid>",
  "full_name": "Subscription for 3 months",
  "button_label": "Subscription · 3m",
  "version": 2
}
```

Omit `version` only when creating a missing localization. Existing rows require their current version. Stale product or localization writes return `concurrency_conflict` instead of silently overwriting another edit.

## Pre-wallet sequence

This contract is the first writable administration surface after role-based navigation. Pricing, users, orders, global listings and manual fulfillment remain separate atomic changes. Wallet and settlement state are explicitly out of scope.
