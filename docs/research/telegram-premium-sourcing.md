# Telegram Premium sourcing research

Status: **measurement tooling ready; live MTProto snapshot pending an authorized user session**.

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

The official API documentation does **not** publish a stable Fragment unit-price table. Consequently, "Fragment is cheaper" is currently an unverified hypothesis, not a sourcing assumption. A real Fragment quote must be observed before the provider can be ranked.

## Measurement plan

The read-only probe lives at `tools/research/telegram_premium_sourcing/probe.py` and calls only:

1. `payments.getPremiumGiftCodeOptions`
2. `payments.getStarsTopupOptions`

It never logs in interactively and contains no invoice/payment/gift submission call.

For every returned Premium option it records exact total and per-user unit cost. For every XTR offer it computes the cheapest replenishment plan from the returned Stars top-up packages per fiat currency. The owner-observed 3-month UAH 499 price can be supplied as a baseline (`49900` minor units).

## Provider decision rules

A candidate sourcing route is eligible for implementation only when all of these are true:

1. Telegram documents the purchase route as permitted for the relevant client/account type.
2. The live quote is measured, not inferred from retail screenshots or the developer reward rate.
3. Landed unit cost is below the broker's current fulfillment ceiling with an explicit safety buffer.
4. The route does not require recipient credentials, region spoofing, payment-profile impersonation, or other account-policy workarounds.
5. Quote, payment, fulfillment, and refund evidence can be made idempotent and auditable.
6. Production activation remains separately approval-gated.

## Current conclusion

There is **not yet evidence** that Telegram offers a 3-month unit below UAH 499 to this sourcing account. There are, however, three concrete hypotheses worth measuring:

- `H1`: the account's direct `XTR` Premium offer, replenished through its cheapest Stars top-up package combination, has landed cost below UAH 499;
- `H2`: a returned multi-user gift-code option has lower exact per-user cost than the single-user option;
- `H3`: a Fragment larger-purchase quote has lower per-user cost than Premium Bot/direct gift pricing.

`H1` and `H2` can now be answered by one read-only MTProto probe run. `H3` still requires a Fragment quote observation because Telegram does not expose Fragment's live price table in the documented core API.

## Official sources

- https://core.telegram.org/method/payments.getPremiumGiftCodeOptions
- https://core.telegram.org/constructor/premiumGiftCodeOption
- https://core.telegram.org/api/premium
- https://core.telegram.org/api/giveaways
- https://core.telegram.org/constructor/inputInvoicePremiumGiftStars
- https://core.telegram.org/method/payments.getStarsTopupOptions
- https://core.telegram.org/constructor/starsTopupOption
- https://core.telegram.org/api/stars
