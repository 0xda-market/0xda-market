# Current project state

This document summarizes the implemented 0xda-market core contract as of 2026-08-11. Architecture documents remain authoritative for individual boundaries; this page is the cross-cutting snapshot.

## Market authority

The buyer-facing product price is market-owned. The current price is the latest append-only price row and may be created by explicit administrator pricing or by the automatic pricing worker. Broker asks never become buyer-facing prices directly.

Automatic pricing uses the best valid unit-executable broker ask as its supply anchor, applies bounded market-owned routing headroom, and derives the minimum solvent client price through the same profitability policy used at reservation time. It may create or raise a client price, but it does not automatically lower an already-profitable price.

A broker listing is executable only when its normalized USDT supply cost satisfies the configured marketplace margin, settlement cost, and supply buffer. Supply that fails this gate remains visible to broker/admin surfaces but cannot be reserved for a client quote.

## Broker incentive and routing

Eligible broker supply is ranked privately by normalized executable cost. Exact competitor asks and identities are never exposed.

Routing is price-sensitive rather than tier-fixed. With one executable broker, that broker receives 100% of allocations. With multiple executable brokers, the default policy splits 10% of traffic evenly as a reserve pool and distributes the remaining 90% through a quadratic price score inside a 10% competitive spread from the best normalized ask. An offer at or beyond that spread remains reserve-only while it is still profitable.

Inside the competitive spread, lowering an executable ask improves expected order share without requiring a rank crossover. Crossing from reserve-only into the competitive spread restores access to the price-performance pool. Equal asks receive equal economic weight. Quote-ID hashing keeps allocation replay-stable, and each broker contributes at most one candidate per SKU.

The broker economic invariant is exact: `broker ask = broker earning` for fulfilled allocated quantity. Marketplace pricing, fees, settlement costs, and routing do not reduce the promised broker payable.

## Broker earnings and payouts

Fulfilled broker allocations produce durable earnings with lifecycle states from pending through available, payout-queued, and paid. Brokers can read their earnings and balances, configure a USDT payout destination/profile, queue their full currently available balance, and inspect payout history.

Payout batches snapshot the exact earning set, amount, network, and destination. Core allows at most one queued/processing payout per broker, derives payout idempotency from the seller plus exact earning set, rejects duplicate transfer references on the same network, and reconciles the complete attached earning aggregate before any paid transition.

The current payout execution boundary is provider-agnostic and manual: core owns accounting, queueing, confirmation, and invariants, while actual external USDT transfer execution remains a separate adapter responsibility.

## Settlement

Core owns a provider-neutral settlement boundary with durable settlement state and events. The manual settlement provider declares execution cost, creates pending settlement state, and requires trusted confirmation before broker inventory is committed and fulfillment begins.

Generic integer-unit payment settlement is also available behind an explicit runtime composition contract. Concrete provider keys, unit codes, valuations, SKU allow-lists, maturity delays, protocol methods, and provider-side validation are supplied by the owning adapter or deployment configuration rather than encoded as provider policy in core.

Settlement costs feed the same profitability policy used by pricing and execution. The browser cannot assert successful payment and does not own settlement state transitions.

## FX and localized client pricing

Localized pricing is a two-step server-owned sequence:

1. **FX acquisition:** a dedicated refresh process fetches a USDT-based exchange-rate snapshot from an outward data adapter, validates it, converts it into the internal `USDT per currency unit` contract, and persists it atomically with provider provenance.
2. **Presentation:** core performs exact conversion from the authoritative USDT price and then applies the configured currency-aware upward rounding strategy.

API requests never call the external FX provider directly. Persisted non-USDT rates fail closed after the freshness TTL; USDT remains fixed at 1.

The supported localized-pricing currency set currently includes USDT, EUR, GBP, CHF, PLN, CZK, and HUF. Language selection and currency selection are separate concerns.

## Catalog and localization

The product catalog is database-backed and localized independently from locale-neutral product state. `en_US` is the canonical fallback. The current buyer-facing catalog contains the marketable products defined by the catalog contract, while currency rows remain non-marketable platform references for FX.

A product can be listed but not executable: `listed` means active broker inventory exists, while `available` means core can safely quote it under pricing, FX freshness, inventory, and positive-margin gates.

## Browser and channel boundaries

`core` owns products, users, roles, prices, FX, broker listings, routing, reservations, quotes, orders, settlement state, broker earnings, payout accounting, profitability, and provider-neutral fulfillment contracts.

`0xda-market/webapp-core` owns reusable browser state and interaction flows. Channel repositories own authentication, signed host transport, shell presentation, provider SDK integration, and deployment entry points.

The browser renders authoritative server amounts. It does not calculate FX, profitability, broker allocation, inventory balances, settlement confirmation, earnings, or payout accounting.

## Research and documentation boundary

Provider-specific research, SDK experiments, protocol probes, economic observations, and cross-repository product/domain documentation belong in `0xda-market/docs` or the owning adapter repository. They do not belong in core under `research`, `researches`, `tools`, or generic documentation paths.

Core documentation is limited to provider-neutral implementation and architecture contracts owned by this service. CI enforces that distinction through `test/architecture_boundaries_test.rb`.

## Delivery state

The implemented path includes:

- database-backed products and localizations;
- append-only market-owned client pricing with automatic price discovery;
- broker-owned finite inventory listings;
- reservation-aware quantity accounting;
- profitability gating using settlement costs;
- deterministic private broker supply allocation;
- durable provider-neutral settlement state;
- broker earnings ledger and self-service payout queue/accounting;
- automated FX acquisition and freshness enforcement;
- localized client price presentation;
- quote, acceptance, payment-pending, fulfillment, and refresh lifecycle surfaces;
- channel-neutral browser/application contracts.

Concrete payment-provider activation, automated external payout execution, refunds/disputes, and provider-specific automated fulfillment remain adapter-owned concerns rather than core-owned behavior.
