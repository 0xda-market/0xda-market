# Telegram Premium sourcing research

Status: **live MTProto measurement complete for the current sourcing account; normalized quote comparison added**.

This research asks one operational question: can a 0xda-market broker fulfill Telegram Premium below the owner-observed Premium Bot gift price while staying inside Telegram-supported flows?

## Observed baseline

On 2026-08-11 the owner supplied a Premium Bot screenshot showing these gift prices in UAH:

| Duration | Observed price | Approx. monthly cost |
| --- | ---: | ---: |
| 3 months | UAH 499 | UAH 166.33 |
| 6 months | UAH 659 | UAH 109.83 |
| 12 months | UAH 1,199 | UAH 99.92 |

This is a UI observation, not an API guarantee. It is only a comparison baseline and can change.

## Telegram contracts verified

### Premium options

`payments.getPremiumGiftCodeOptions` returns `PremiumGiftCodeOption` values containing `users`, `months`, `currency`, and total `amount`. Telegram marks this method as **user-only**, so the existing 0xda-market Bot API credential cannot query it.

Telegram's Premium documentation distinguishes the normal direct-gift flow from multi-user gift/giveaway options:

- direct gifting uses the options where `users == 1`;
- options where `users > 1` belong to the multi-user gift/giveaway family and must not be assumed to be a volume discount without measuring the returned amounts;
- a `users/months` tuple may have a native-currency offer and an optional `XTR` offer;
- Telegram explicitly says unofficial clients should display and use only `XTR` options for the direct Premium gift flow;
- an XTR direct gift is represented by `inputInvoicePremiumGiftStars`.

Therefore 0xda-market must **not** treat a lower native-currency MTProto option as an automatically valid production purchase rail. Native values are observational data; the safe direct-client candidate is the XTR flow unless Telegram documents another allowed route.

### Stars acquisition

`payments.getStarsTopupOptions` is also user-only and returns the actual top-up packages available to the current account as `stars`, `currency`, and `amount`.

This matters because Telegram's developer reward value per Star is not the buyer's acquisition cost. To decide whether an XTR Premium gift beats UAH 499, we need the current Stars top-up packages for the sourcing account and must solve for the cheapest package combination that acquires at least the gift's required Stars.

The repository probe does exactly that and records package overbuy explicitly.

### Multi-gift and Fragment

Telegram documents the newer gift-code/giveaway flow as capable of gifting Premium to multiple specific contacts. It also names two alternative payment paths: Premium Bot and Fragment, and explicitly says Fragment allows larger purchases.

The official API documentation does **not** publish a stable Fragment unit-price table. Consequently, Fragment pricing must be observed independently before it can be ranked.

## Live measurements: 2026-08-11

The owner ran the read-only MTProto probe using an authorized Telegram user session. The session returned 33 Premium options and 15 Stars top-up options.

### Direct Premium offers

The measured single-user native/XTR pairs were:

| Duration | Native offer | XTR offer |
| --- | ---: | ---: |
| 3 months | UAH 499 | 1,000 XTR |
| 6 months | UAH 659 | 1,500 XTR |
| 12 months | UAH 1,199 | 2,500 XTR |

For the measured UAH Stars top-up packages, the cheapest replenishment costs for those XTR requirements were:

| Duration | Required XTR | Cheapest measured UAH replenishment | Native comparison |
| --- | ---: | ---: | ---: |
| 3 months | 1,000 | UAH 778 | UAH 499 |
| 6 months | 1,500 | UAH 1,159 | UAH 659 |
| 12 months | 2,500 | UAH 1,929 | UAH 1,199 |

Therefore the measured Stars-replenishment path is materially more expensive than the native UAH observations for this account. No 3-month source below UAH 499 was found through that path.

### Multi-user observations

Most multi-user native offers were approximately flat or slightly more expensive per user. The notable measured exception was six months for two users:

- total: UAH 1,299;
- exact unit cost: UAH 649.50;
- single-user comparison: UAH 659.

The owner separately performed a read-only `payments.getPaymentForm` check for two specific recipients and observed a real `PaymentForm` at UAH 1,299 through the `smartglocal` provider. That manual check was outside this repository probe and does not change the probe's safety boundary: the committed probe still contains no invoice or payment-form call.

This is evidence that the quoted multi-user total is payable, but it is not evidence that the route can or should be used as a generic single-customer fulfillment primitive.

### Fragment observations

The owner also inspected Fragment's Premium purchase UI without submitting a transaction. For quantities 50 and 1,000, the effective USDC unit prices were approximately stable rather than decreasing with quantity:

| Duration | Quantity 50 | Quantity 1,000 |
| --- | ---: | ---: |
| 3 months | 11.2806 USDC/user | 11.285 USDC/user |
| 6 months | 15.0434 USDC/user | 15.049 USDC/user |
| 12 months | 27.0842 USDC/user | 27.095 USDC/user |

The small differences are consistent with quote/rounding variation, not a volume tier. The measured Fragment UI therefore provided no evidence of a quantity discount at those two sizes. Fragment also remains a channel/prepaid-giveaway rail rather than a deterministic direct-gift-to-one-client primitive.

## Normalized quote contract

The read-only probe now emits native-currency observations as `sourcing-quote.v1` records for provider comparison.

The minimum normalized fields are:

- `provider`;
- operator-supplied `region` plus returned `currency`;
- `sku`;
- `quantity`;
- total and exact unit acquisition price in minor units;
- observation timestamp.

For the measured direct three-month UAH offer, the normalized quote shape is:

```json
{
  "schema": "sourcing-quote.v1",
  "provider": "telegram_native",
  "region": "UA",
  "currency": "UAH",
  "sku": "premium_3m",
  "quantity": 1,
  "acquisition_price_minor": 49900,
  "unit_acquisition_price_minor": 49900
}
```

The actual report adds `offer_kind` and `observed_at`. The price is live evidence, not a hard-coded catalog value.

Telegram does not return a market/country field with Premium gift options, so `region` is never inferred from `UAH`. It is supplied only when the operator independently knows the sourcing context. This prevents currency from becoming an accidental proxy for account region.

Normalized quotes are comparison evidence only. They do not promote a route into production, and they do not bypass Telegram contract, fulfillment, refund, idempotency, audit, margin, or production-approval requirements.

## Measurement plan

The read-only probe lives at `tools/research/telegram_premium_sourcing/probe.py` and calls only:

1. `payments.getPremiumGiftCodeOptions`
2. `payments.getStarsTopupOptions`

It never logs in interactively and contains no invoice/payment/gift submission call.

For every returned Premium option it records exact total and per-user unit cost. For every XTR offer it computes the cheapest replenishment plan from the returned Stars top-up packages per fiat currency. Native-currency observations are additionally normalized into provider-agnostic quote records that can later be compared across legitimate broker contexts.

## Provider decision rules

A candidate sourcing route is eligible for implementation only when all of these are true:

1. Telegram documents the purchase route as permitted for the relevant client/account type.
2. The live quote is measured, not inferred from retail screenshots or the developer reward rate.
3. Landed unit cost is below the broker's current fulfillment ceiling with an explicit safety buffer.
4. The route does not require recipient credentials, region spoofing, payment-profile impersonation, or other account-policy workarounds.
5. Quote, payment, fulfillment, and refund evidence can be made idempotent and auditable.
6. Production activation remains separately approval-gated.

## Current conclusion

For the measured sourcing account and official rails tested on 2026-08-11:

- `H1` is rejected: buying/replenishing the required Stars is substantially more expensive than the native UAH Premium observations;
- `H2` finds only a small six-month two-recipient advantage (UAH 649.50/user versus UAH 659), not a lower three-month source;
- `H3` is rejected as a volume-discount hypothesis at quantities 50 and 1,000: Fragment unit pricing remained effectively flat and the rail is not direct single-recipient fulfillment.

The lowest measured three-month native quote remains **UAH 499** for this sourcing context.

The next research step is not region spoofing. It is collecting the same normalized quote contract from other legitimate broker/account contexts and comparing acquisition cost, route eligibility, capacity, freshness, and fulfillment guarantees. This maps cleanly onto the existing 0xda-market broker model: brokers compete by providing verifiable supply rather than by changing the client's visible product contract.

## Official sources

- https://core.telegram.org/method/payments.getPremiumGiftCodeOptions
- https://core.telegram.org/constructor/premiumGiftCodeOption
- https://core.telegram.org/api/premium
- https://core.telegram.org/api/giveaways
- https://core.telegram.org/constructor/inputInvoicePremiumGiftStars
- https://core.telegram.org/method/payments.getStarsTopupOptions
- https://core.telegram.org/constructor/starsTopupOption
- https://core.telegram.org/api/stars
