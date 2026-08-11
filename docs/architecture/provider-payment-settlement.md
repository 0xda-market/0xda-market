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
  -> provider funds maturity
  -> broker earning available for payout
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

An integer-unit provider may also define `funds_hold_seconds`. When payment is confirmed, the settlement snapshots `funds_available_at = confirmed_at + funds_hold_seconds`. Fulfillment may still proceed after the payment is verified, but the associated broker earning remains `pending` until that provider-funds maturity boundary is reached. Matured earnings are promoted lazily when broker balances/listings/payouts are read, so no separate timer worker is required.

This separates two different truths:

```text
payment confirmed     = buyer paid and fulfillment may proceed
funds available       = market may safely treat provider proceeds as payout-backed
broker earning paid   = market transferred the matured earning to the broker
```

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
- A broker earning cannot enter an available payout batch before the provider's durable `funds_available_at` boundary.
- Existing immediate-settlement providers retain their existing immediate broker-earning behavior because they expose no future maturity boundary.

## Telegram Stars composition

The first concrete composition uses Telegram Stars (`XTR`) for Telegram digital-goods checkout. The concrete provider name remains outside `config.ru`; `Composition::SettlementProviderFactory` owns the mapping.

Runtime selection:

```text
MARKET_PAYMENT_PROVIDER=telegram_stars
TELEGRAM_STARS_USDT_PER_STAR=<explicit current market valuation>
TELEGRAM_STARS_PAYMENT_SKUS=premium_3m,premium_6m,premium_9m
TELEGRAM_STARS_REWARD_HOLD_SECONDS=<at least 1814400>
```

`TELEGRAM_STARS_USDT_PER_STAR` is intentionally not hard-coded. Provider economics can change and must be reviewed against Telegram's current official terms before activation.

Telegram currently documents a USD-equivalent developer reward per Star and states that received Stars may remain unavailable for rewards for up to 21 days. It also reserves the ability to debit Stars in refund/abuse cases. Core therefore defaults the Stars composition to a conservative 21-day (`1,814,400` second) reward hold and refuses a lower configured value. The hold may be raised operationally if the provider contract or market risk policy requires it.

The default eligible SKU set contains only Telegram Premium products. `stars_*` products are deliberately excluded from the initial Stars checkout to avoid creating a Stars-for-Stars sale path without a separate policy and compliance review.

## Broker payout relationship

`broker ask = broker earning` remains unchanged. The provider hold changes only **when** that earning becomes payout-eligible, not its amount.

For a delayed provider settlement:

```text
fulfilled order
  -> earning state: pending
  -> available_at: provider funds maturity
  -> maturity reached
  -> earning state: available
  -> payout queue may include it
```

This prevents 0xda-market from paying a broker out of an unsettled provider receivable by default.

## Activation contract

The real provider is opt-in. Merging this code does not activate payments.

The Telegram adapter must be enabled and able to create/verify invoices before the core is switched from its existing settlement mode to the real provider. If either side is not ready, keep `MARKET_PAYMENT_PROVIDER` unset.

Before production activation, re-check Telegram's current reward valuation, reward-availability delay, refund/debit rules and any applicable fees. Set the Stars valuation deliberately; never infer it from what a user pays to acquire Stars, because Telegram's own terms distinguish user acquisition cost from developer reward value.

No production deployment or environment mutation is part of this change.
