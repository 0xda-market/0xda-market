#!/usr/bin/env python3
"""Read-only Telegram Premium sourcing probe.

The live path performs only two MTProto read methods:
- payments.getPremiumGiftCodeOptions
- payments.getStarsTopupOptions

It intentionally does not perform login, invoice creation, payment-form retrieval,
payment submission, gift delivery, or any production mutation.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from math import gcd
from pathlib import Path
from typing import Any

MAX_DP_STARS = 200_000


def _int(value: Any, field: str) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be an integer") from exc
    return parsed


def _exact_unit_amount(amount: int, users: int) -> int | str:
    if amount % users == 0:
        return amount // users
    divisor = gcd(amount, users)
    return f"{amount // divisor}/{users // divisor}"


def _premium_dict(option: Any) -> dict[str, Any]:
    return {
        "users": _int(getattr(option, "users"), "users"),
        "months": _int(getattr(option, "months"), "months"),
        "currency": str(getattr(option, "currency")),
        "amount_minor": _int(getattr(option, "amount"), "amount"),
        "store_product": getattr(option, "store_product", None),
        "store_quantity": getattr(option, "store_quantity", None),
    }


def _topup_dict(option: Any) -> dict[str, Any]:
    return {
        "stars": _int(getattr(option, "stars"), "stars"),
        "currency": str(getattr(option, "currency")),
        "amount_minor": _int(getattr(option, "amount"), "amount"),
        "extended": bool(getattr(option, "extended", False)),
        "store_product": getattr(option, "store_product", None),
    }


def _validate_premium(option: dict[str, Any]) -> dict[str, Any]:
    users = _int(option.get("users"), "users")
    months = _int(option.get("months"), "months")
    amount = _int(option.get("amount_minor"), "amount_minor")
    currency = str(option.get("currency", "")).upper()
    if users <= 0 or months <= 0 or amount < 0 or not currency:
        raise ValueError("invalid Premium gift option")
    return {
        "users": users,
        "months": months,
        "currency": currency,
        "amount_minor": amount,
        "unit_amount_minor": _exact_unit_amount(amount, users),
        "offer_kind": "direct_gift" if users == 1 else "multi_gift_candidate",
        "store_product": option.get("store_product"),
        "store_quantity": option.get("store_quantity"),
    }


def _validate_topup(option: dict[str, Any]) -> dict[str, Any]:
    stars = _int(option.get("stars"), "stars")
    amount = _int(option.get("amount_minor"), "amount_minor")
    currency = str(option.get("currency", "")).upper()
    if stars <= 0 or amount < 0 or not currency:
        raise ValueError("invalid Stars top-up option")
    return {
        "stars": stars,
        "currency": currency,
        "amount_minor": amount,
        "extended": bool(option.get("extended", False)),
        "store_product": option.get("store_product"),
    }


def min_topup_cost(target_stars: int, packages: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Return the cheapest package combination that acquires at least target_stars."""

    target_stars = _int(target_stars, "target_stars")
    if target_stars <= 0:
        raise ValueError("target_stars must be positive")
    if not packages:
        return None
    normalized = [_validate_topup(item) for item in packages]
    if target_stars > MAX_DP_STARS:
        return {
            "status": "skipped",
            "reason": f"target exceeds {MAX_DP_STARS}-star analysis limit",
        }

    max_pack = max(item["stars"] for item in normalized)
    limit = target_stars + max_pack - 1
    costs: list[int | None] = [None] * (limit + 1)
    counts: list[int | None] = [None] * (limit + 1)
    previous: list[tuple[int, int] | None] = [None] * (limit + 1)
    costs[0] = 0
    counts[0] = 0

    for current in range(limit + 1):
        if costs[current] is None:
            continue
        current_count = counts[current]
        if current_count is None:
            raise RuntimeError("top-up dynamic-program state is inconsistent")
        for index, package in enumerate(normalized):
            nxt = current + package["stars"]
            if nxt > limit:
                continue
            candidate_cost = costs[current] + package["amount_minor"]
            candidate_count = current_count + 1
            existing_cost = costs[nxt]
            existing_count = counts[nxt]
            if (
                existing_cost is None
                or candidate_cost < existing_cost
                or (
                    candidate_cost == existing_cost
                    and existing_count is not None
                    and candidate_count < existing_count
                )
            ):
                costs[nxt] = candidate_cost
                counts[nxt] = candidate_count
                previous[nxt] = (current, index)

    candidates = [
        stars
        for stars in range(target_stars, limit + 1)
        if costs[stars] is not None
    ]
    if not candidates:
        return None
    acquired = min(candidates, key=lambda stars: (costs[stars], stars - target_stars, counts[stars]))

    package_counts = [0] * len(normalized)
    cursor = acquired
    while cursor:
        step = previous[cursor]
        if step is None:
            raise RuntimeError("top-up plan reconstruction failed")
        prior, package_index = step
        package_counts[package_index] += 1
        cursor = prior

    selected = []
    for index, count in enumerate(package_counts):
        if count:
            selected.append({
                "stars": normalized[index]["stars"],
                "amount_minor": normalized[index]["amount_minor"],
                "count": count,
            })

    return {
        "status": "ok",
        "target_stars": target_stars,
        "acquired_stars": acquired,
        "overbuy_stars": acquired - target_stars,
        "cost_minor": costs[acquired],
        "package_count": counts[acquired],
        "packages": selected,
    }


def analyze(
    premium_options: list[dict[str, Any]],
    topup_options: list[dict[str, Any]],
    *,
    baseline_currency: str | None = None,
    baseline_minor: int | None = None,
    baseline_months: int = 3,
) -> dict[str, Any]:
    premiums = [_validate_premium(item) for item in premium_options]
    topups = [_validate_topup(item) for item in topup_options]
    premiums.sort(key=lambda item: (item["months"], item["users"], item["currency"], item["amount_minor"]))
    topups.sort(key=lambda item: (item["currency"], item["amount_minor"], item["stars"]))

    by_currency: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for topup in topups:
        by_currency[topup["currency"]].append(topup)

    xtr_acquisition = []
    for offer in premiums:
        if offer["currency"] != "XTR":
            continue
        estimates = {}
        for currency, packages in sorted(by_currency.items()):
            if currency == "XTR":
                continue
            plan = min_topup_cost(offer["amount_minor"], packages)
            if plan is not None:
                estimates[currency] = plan
        xtr_acquisition.append({
            "users": offer["users"],
            "months": offer["months"],
            "required_stars": offer["amount_minor"],
            "topup_estimates": estimates,
        })

    baseline = None
    if (baseline_currency is None) != (baseline_minor is None):
        raise ValueError("baseline_currency and baseline_minor must be provided together")
    if baseline_currency is not None:
        currency = baseline_currency.upper()
        amount = _int(baseline_minor, "baseline_minor")
        months = _int(baseline_months, "baseline_months")
        matches = [
            item
            for item in premiums
            if item["users"] == 1 and item["months"] == months and item["currency"] == currency
        ]
        baseline = {
            "currency": currency,
            "months": months,
            "amount_minor": amount,
            "matching_offers": [
                {
                    **item,
                    "delta_minor": item["amount_minor"] - amount,
                    "below_baseline": item["amount_minor"] < amount,
                }
                for item in matches
            ],
        }

    return {
        "premium_options": premiums,
        "stars_topup_options": topups,
        "xtr_acquisition_estimates": xtr_acquisition,
        "baseline_comparison": baseline,
    }


async def fetch_live() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    try:
        from telethon import TelegramClient, functions
        from telethon.sessions import StringSession
    except ImportError as exc:
        raise RuntimeError(
            "Telethon is required for live mode; install tools/research/telegram_premium_sourcing/requirements.txt"
        ) from exc

    api_id = os.environ.get("TELEGRAM_API_ID")
    api_hash = os.environ.get("TELEGRAM_API_HASH")
    session_string = os.environ.get("TELEGRAM_SESSION_STRING")
    session_file = os.environ.get("TELEGRAM_SESSION_FILE")
    if not api_id or not api_hash:
        raise RuntimeError("TELEGRAM_API_ID and TELEGRAM_API_HASH are required")
    if bool(session_string) == bool(session_file):
        raise RuntimeError("set exactly one of TELEGRAM_SESSION_STRING or TELEGRAM_SESSION_FILE")

    session: Any = StringSession(session_string) if session_string else str(Path(session_file).expanduser())
    client = TelegramClient(session, int(api_id), api_hash)
    await client.connect()
    try:
        if not await client.is_user_authorized():
            raise RuntimeError("Telegram user session is not authorized; this probe never performs login")
        identity = await client.get_me()
        if getattr(identity, "bot", False):
            raise RuntimeError("payments.getPremiumGiftCodeOptions requires a user session, not a bot session")

        premium = await client(functions.payments.GetPremiumGiftCodeOptionsRequest(boost_peer=None))
        topups = await client(functions.payments.GetStarsTopupOptionsRequest())
        return ([_premium_dict(item) for item in premium], [_topup_dict(item) for item in topups])
    finally:
        await client.disconnect()


def load_snapshot(path: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return data["premium_options"], data["stars_topup_options"]


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Read-only Telegram Premium sourcing probe")
    result.add_argument("--input", help="Analyze a previously captured raw snapshot instead of calling Telegram")
    result.add_argument("--output", help="Write JSON report to this path; stdout is always supported")
    result.add_argument("--pretty", action="store_true", help="Pretty-print JSON")
    result.add_argument("--baseline-currency")
    result.add_argument("--baseline-minor", type=int)
    result.add_argument("--baseline-months", type=int, default=3)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.input:
            premium, topups = load_snapshot(args.input)
            source = "snapshot"
        else:
            premium, topups = asyncio.run(fetch_live())
            source = "telegram_mtproto"

        report = {
            "schema": "telegram-premium-sourcing.v1",
            "collected_at": datetime.now(timezone.utc).isoformat(),
            "source": source,
            "read_methods": [
                "payments.getPremiumGiftCodeOptions",
                "payments.getStarsTopupOptions",
            ],
            "write_operations": False,
            "analysis": analyze(
                premium,
                topups,
                baseline_currency=args.baseline_currency,
                baseline_minor=args.baseline_minor,
                baseline_months=args.baseline_months,
            ),
        }
        payload = json.dumps(report, indent=2 if args.pretty else None, sort_keys=True)
        if args.output:
            Path(args.output).write_text(payload + "\n", encoding="utf-8")
        else:
            print(payload)
        return 0
    except (KeyError, OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
        print(f"telegram-premium-sourcing: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
