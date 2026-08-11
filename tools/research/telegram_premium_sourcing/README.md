# Telegram Premium sourcing probe

This tool measures Telegram-owned Premium gift and Stars acquisition offers without making a purchase.

Canonical cross-repository findings live in `0xda-market/docs` under `researches/telegram-premium-sourcing/`. This README documents only the executable probe and its safety/usage contract.

## Safety boundary

Live mode is intentionally read-only. It invokes exactly:

- `payments.getPremiumGiftCodeOptions`
- `payments.getStarsTopupOptions`

It does **not** perform interactive login, create invoices, request payment forms, submit payment forms, launch giveaways, send gifts, or mutate 0xda-market production state.

Telegram documents `payments.getPremiumGiftCodeOptions` and `payments.getStarsTopupOptions` as user-only MTProto methods. A Bot API token is therefore not sufficient. Use an already-authorized **user** MTProto session and treat that session exactly like a password.

Never commit `api_hash`, a session string, or a `.session` file. The local ignore rules cover the default session artifacts, but the operator remains responsible for keeping credentials outside the repository.

## Why both methods are measured

`payments.getPremiumGiftCodeOptions` returns the current Premium offer tuples (`users`, `months`, `currency`, `amount`). Some tuples may be denominated in `XTR`.

`payments.getStarsTopupOptions` returns the current Stars acquisition packages (`stars`, `currency`, `amount`). The probe combines those packages with each XTR Premium offer and computes the cheapest package combination that acquires at least the required Stars. This is the buyer-side replenishment cost; it must not be confused with Telegram's developer reward value per Star.

The algorithm intentionally permits overbuying Stars because Telegram sells fixed top-up packages. The report records both the acquired amount and the overbuy.

## Normalized sourcing quotes

The report also emits native-currency Premium observations as `sourcing-quote.v1` records so quotes from different legitimate broker/account contexts can be compared without coupling the comparison layer to Telegram's raw MTProto shape.

Each quote contains:

- `provider`: currently `telegram_native`;
- `region`: optional operator-supplied two-letter country context;
- `currency`;
- `sku`, such as `premium_3m`;
- `quantity`;
- `acquisition_price_minor` and exact `unit_acquisition_price_minor`;
- `offer_kind`;
- `observed_at`.

Telegram does not return a country/market field with `payments.getPremiumGiftCodeOptions`. The probe therefore **never infers region from currency**. Supply `--market-region UA` only when that context is known independently. Omitting the flag records `region: null`.

XTR offers are not emitted as `telegram_native` sourcing quotes. Their landed acquisition cost remains in `xtr_acquisition_estimates`, where it is derived from actual Stars top-up packages rather than from the nominal XTR amount.

A normalized quote is measurement evidence, not automatic provider eligibility. The production provider decision rules still apply.

## Setup

Create an isolated environment; this dependency is research-only and is not part of the core runtime:

```bash
cd tools/research/telegram_premium_sourcing
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

The pinned client is Telethon 1.44.0.

Set Telegram API application credentials and exactly one already-authorized user session source:

```bash
export TELEGRAM_API_ID='...'
export TELEGRAM_API_HASH='...'
export TELEGRAM_SESSION_FILE='/absolute/path/outside/repository/premium-sourcing.session'
```

Headless environments may use `TELEGRAM_SESSION_STRING` instead of `TELEGRAM_SESSION_FILE`, but a session string is a high-value secret and should be stored only in an appropriate secret manager.

The probe refuses to start if the session is not already authorized. It never asks for a phone number, login code, or 2FA password.

## Run

For the owner-observed 2026-08-11 Premium Bot baseline of UAH 499.00 for three months and a known Ukrainian market context:

```bash
python3 probe.py \
  --market-region UA \
  --baseline-currency UAH \
  --baseline-minor 49900 \
  --baseline-months 3 \
  --pretty
```

The resulting direct native quote includes the comparable shape:

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

The actual report also includes `offer_kind` and `observed_at`; the values above illustrate the normalized contract and are not hard-coded into the probe.

To retain a reviewed report without retaining credentials:

```bash
python3 probe.py --market-region UA --pretty --output /tmp/telegram-premium-sourcing.json
```

The output contains no Telegram user identifier and no session data.

## Offline analysis

A raw snapshot can be analyzed without Telegram connectivity:

```json
{
  "premium_options": [
    {"users": 1, "months": 3, "currency": "XTR", "amount_minor": 300}
  ],
  "stars_topup_options": [
    {"stars": 100, "currency": "UAH", "amount_minor": 10000}
  ]
}
```

```bash
python3 probe.py --input snapshot.json --market-region UA --pretty
```

## Interpretation rules

- `users == 1` is labeled `direct_gift`.
- `users > 1` is labeled only `multi_gift_candidate`; the tool does not assume a wholesale discount.
- native-currency options are useful for observation and same-currency comparison, but Telegram's Premium documentation says unofficial clients should display and use only `XTR` options in the direct gift flow. A native-currency MTProto offer is therefore **not** treated as a production payment route for 0xda-market.
- an XTR acquisition estimate is only the cost of replenishing the required Stars from currently returned top-up packages. Existing Stars balance, taxes, payment-provider effects, regional restrictions, and Fragment quotes can change the actual landed cost.
- the tool never converts Telegram's developer reward rate into a buyer acquisition rate.
- normalized quotes compare observations; they do not bypass route eligibility, fulfillment, refund, or production approval requirements.

## Official contracts

- https://core.telegram.org/method/payments.getPremiumGiftCodeOptions
- https://core.telegram.org/api/premium
- https://core.telegram.org/api/giveaways
- https://core.telegram.org/method/payments.getStarsTopupOptions
- https://core.telegram.org/api/stars
- https://core.telegram.org/constructor/inputInvoicePremiumGiftStars

Fragment is documented by Telegram as an alternative payment flow that supports larger purchases, but the core API documentation does not publish a deterministic Fragment unit-price table. Fragment must therefore be measured separately from an actual read-only quote/check-out view before it can be ranked as a sourcing provider.
