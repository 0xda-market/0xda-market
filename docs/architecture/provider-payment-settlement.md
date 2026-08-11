# Provider payment settlement

## Purpose

0xda-market keeps marketplace economics canonical in USDT while allowing a channel adapter to collect payment through a provider whose client-facing unit differs from USDT.

Core does not trust browser payment state and does not call channel APIs. The durable source of truth for money movement remains `market.settlements`.

## Boundary

```text
channel UI
  -> quote / accept
  -> core snapshots provider payment terms
  -> provider UI
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

The valuation is snapshotted into the order payment terms and settlement record. A provider confirmation must match all of the following exactly:

- provider key;
- provider currency;
- integer provider amount;
- owning market client;
- external payment reference.

The settled USDT-equivalent value must not be below the original canonical market amount.

An integer-unit provider may define `funds_hold_seconds`. When payment is confirmed, the settlement snapshots `funds_available_at = confirmed_at + funds_hold_seconds`. Fulfillment may proceed after payment verification, while the associated broker earning remains `pending` until the provider-funds maturity boundary is reached. Matured earnings are promoted lazily when broker balances, earnings, or payouts are read.

This separates three independent truths:

```text
payment confirmed     = client paid and fulfillment may proceed
funds available       = market may treat provider proceeds as payout-backed
broker earning paid   = market transferred the matured earning to the broker
```

## Generic runtime composition

Core accepts only provider-neutral payment configuration. A concrete channel or payment adapter supplies the opaque provider key and provider economics at deployment time.

```text
MARKET_PAYMENT_PROVIDER=<opaque provider key>
MARKET_PAYMENT_KIND=integer_unit
MARKET_PAYMENT_CURRENCY=<provider unit code>
MARKET_PAYMENT_USDT_PER_UNIT=<reviewed valuation>
MARKET_PAYMENT_SKUS=<comma-separated eligible SKUs>
MARKET_PAYMENT_FUNDS_HOLD_SECONDS=<non-negative maturity delay>
```

No concrete provider key, SDK, protocol method, provider-specific rate, product allow-list, or provider-specific maturity policy belongs in core composition defaults.

Provider-specific activation guidance, economic assumptions, operational research, and external API contracts belong in the owning adapter repository or the canonical `0xda-market/docs` repository.

## Safety invariants

- A provider payment configuration without a settlement provider fails closed.
- A provider payment cannot be confirmed from a browser callback alone.
- A settlement is created when the accepted order enters `payment_pending`.
- Fulfillment remains impossible until settlement verification and payment confirmation succeed.
- Repeating the same external payment reference is idempotent.
- A different external reference for an already-settled order is rejected.
- Expired settlements cannot be confirmed.
- Provider, currency, and amount mismatches cannot route fulfillment.
- Real and mock market payment providers cannot be enabled simultaneously.
- Provider-specific transport, credentials, SDKs, and protocol behavior remain outside core.
- A broker earning cannot enter an available payout batch before the provider's durable `funds_available_at` boundary.
- Providers without a future maturity boundary retain immediate broker-earning availability.

## Broker payout relationship

`broker ask = broker earning` remains unchanged. A provider hold changes only **when** an earning becomes payout-eligible, not its amount.

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

A real provider is opt-in. Merging provider-neutral settlement support does not activate any payment rail.

Before activation, the owning adapter must validate the provider-side payment event, supply reviewed configuration, and preserve the provider key, currency, amount, external reference, and maturity semantics expected by core. Any provider-specific policy belongs outside this repository.
