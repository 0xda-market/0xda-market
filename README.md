# 0xda Market

Provider-agnostic crypto market intelligence engine.

Initially powered by the TON ecosystem and exposed through a Telegram bot, while remaining independent of any specific blockchain, exchange or marketplace.

The project collects market data, normalizes it into a common domain model, computes trading metrics and produces transparent pricing recommendations.

Current focus:

- TON
- USDT (TON Jetton)

## Planned providers

### Blockchains

- TON
- Ethereum
- Solana
- Base
- BNB Chain

### Decentralized Exchanges

- STON.fi
- DeDust
- Uniswap
- PancakeSwap
- Jupiter

### Centralized Exchanges

- Binance
- Bybit
- WhiteBIT
- Kraken
- Coinbase Exchange

### Marketplaces

- Fragment
- Telegram Premium
- Telegram Stars
- Telegram Gifts

---

## Goals

Instead of predicting markets, 0xda Market aims to measure them.

Every recommendation should be reproducible from observable market data.

---

## Features

### Asset markets

- best bid
- best ask
- weighted ask
- spread
- last trade
- liquidity estimation
- fee estimation
- historical snapshots
- pricing recommendations

### Product marketplaces

- floor price
- average ask
- median ask
- new listings
- confirmed sales
- estimated sale time
- fee estimation
- pricing recommendations

---

## Architecture

```
                Interfaces

Telegram Bot
REST API
CLI

        │

Market Engine

        │

Providers

TON
Ethereum
Solana
Centralized Exchanges

        │

Venues

STON.fi
DeDust
Fragment
...
```

The Market Engine never depends on a specific provider.

TON is simply the first implementation.

---

## Project Status

Early development.

The first milestone is a read-only market intelligence engine for TON / USDT.

---

## Roadmap

### v0.1

- Core domain
- TON provider
- TON/USDT market
- Telegram interface

### v0.2

- Historical snapshots
- Pricing engine
- Alerts

### v0.3

- Multiple liquidity venues
- Market aggregation

### v0.4

- Telegram Premium

### v0.5

- Telegram Stars

---

## Principles

- provider agnostic
- deterministic calculations
- transparent recommendations
- reproducible metrics
- engineering-first design

---

## License

MIT
