# Localization matrix

Localization has two independent inputs:

1. **language copy** — reusable UI and product names;
2. **regional currency context** — a presentation hint used only when a concrete regional locale is available.

Language must never silently become geography. In particular, Russian is a full interface language for Russian-speaking users outside Russia; `ru_KZ` therefore uses Russian copy but does not select RUB. Likewise `es_MX` uses Spanish copy without selecting EUR.

## Full catalog locales

The catalog ships complete product localizations for:

- `en_US` — canonical fallback;
- `uk_UA` — primary Ukrainian audience;
- `ru_RU` — canonical Russian copy, also used as the language fallback for regional `ru_*` locales;
- `es_ES` — canonical Spanish copy, also used as the language fallback for regional `es_*` locales;
- `pt_BR` — Brazilian Portuguese.

For product copy, resolution order is:

`exact locale -> canonical language locale -> en_US -> products.short_name`

Examples:

- `ru_KZ -> ru_RU -> en_US`;
- `es_MX -> es_ES -> en_US`;
- `de_DE -> en_US` until German is promoted from skeleton to full support.

## Regional currency hints

Currency metadata is regional rather than language-wide:

| Currency | Locales |
| --- | --- |
| USD | `en_US` |
| UAH | `uk_UA` |
| RUB | `ru_RU` |
| EUR | `de_DE`, `fr_FR`, `it_IT`, `es_ES` |
| GBP | `en_GB` |
| CHF | `de_CH`, `fr_CH`, `it_CH` |
| PLN | `pl_PL` |
| CZK | `cs_CZ` |
| HUF | `hu_HU` |

Regional Russian and Spanish locales outside those rows remain currency-neutral and fall back to USDT unless a channel supplies an explicit supported currency. Language-only `ru`, `es`, and `pt` are also currency-neutral because they span multiple countries.

This contract keeps the provider-agnostic core deterministic and lets channel adapters add better country/currency signals later without changing translation semantics.
