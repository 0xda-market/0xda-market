# Provider payment settlement

## Purpose

0xda-market keeps marketplace economics canonical in USDT while allowing a channel adapter to collect payment through a provider whose customer-facing unit is different from USDT.

The core does not trust browser payment state and does not call channel APIs. The durable source of truth for money movement remains `market.settlements`.

## Boundary

```text
channel UI
  -> quote / accept
  -> core snapshots provider payment terms
  -> channel provider UI
  -> authoritative provider event
  -> trusted channel adapter
  -> core settlement confirmation
  -> payment confirmed
  -> inventory committed
  -> fulfillment
```

The order payment document is a projection of the immutable checkout terms. It is not a second settlement ledger.

## Integer-unit providers

`Settlement::IntegerUnitProvider` supports providers that charge an integer number of provider units while the market price remains canonical in USDT.

The market owns an explicit `usdt_per_unit` valuation. The required provider amount is rounded upward:

```text
provider_units = ceil(client_total_usdt / usdt_per_unit)
```

The valuation is snapshotted into the order payment terms and the settlement record. A provider confirmation must match all of the following exactly:

- provider key;
- provider currency;
- integer provider amount;
- owning market customer;
- external payment reference.

The settled USDT-equivalent value must not be below the original canonical market amount.

## Safety invariants

- A provider payment configuration without a settlement provider fails closed.
- A provider payment cannot be confirmed from a browser or Mini App callback alone.
- A settlement is created when the accepted order enters `payment_pending`.
- Fulfillment remains impossible until the settlement is verified and the order payment is confirmed.
- Repeating the same external payment reference is idempotent.
- A different external reference for an already-settled order is rejected.
- Expired settlements cannot be confirmed.
- Provider/currency/amount mismatches cannot route fulfillment.
- Real and mock market payment providers cannot be enabled simultaneously.
- Provider-specific configuration is isolated outside the runtime boundary in the composition layer.

## Telegram Stars composition

The first concrete composition uses Telegram Stars (`XTR`) for Telegram digital-goods checkout. The concrete provider name remains outside `config.ru`; `Composition::SettlementProviderFactory` owns the mapping.

Runtime selection:

```text
MARKET_PAYMENT_PROVIDER=telegram_stars
TELEGRAM_STARS_USDT_PER_STAR=<explicit current market valuation>
TELEGRAM_STARS_PAYMENT_SKUS=premium_3m,premium_6m,premium_9m
```

`TELEGRAM_STARS_USDT_PER_STAR` is intentionally not hard-coded. Provider economics can change and must be reviewed before activation.

The default eligible SKU set contains only Telegram Premium products. `stars_*` products are deliberately excluded from the initial Stars checkout to avoid creating a Stars-for-Stars sale path without a separate policy and compliance review.

## Activation contract

The real provider is opt-in. Merging this code does not activate payments.

The Telegram adapter must be enabled and able to create/verify invoices before the core is switched from its existing settlement mode to the real provider. If either side is not ready, keep `MARKET_PAYMENT_PROVIDER` unset.

No production deployment or environment mutation is part of this change.
