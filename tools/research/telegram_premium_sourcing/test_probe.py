from __future__ import annotations

import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from probe import analyze, min_topup_cost  # noqa: E402


class TelegramPremiumSourcingProbeTest(unittest.TestCase):
    def test_min_topup_cost_finds_cheapest_replenishment_plan(self):
        packages = [
            {"stars": 100, "currency": "UAH", "amount_minor": 8_000},
            {"stars": 250, "currency": "UAH", "amount_minor": 19_000},
        ]

        plan = min_topup_cost(500, packages)

        self.assertEqual("ok", plan["status"])
        self.assertEqual(500, plan["acquired_stars"])
        self.assertEqual(38_000, plan["cost_minor"])
        self.assertEqual(
            [{"stars": 250, "amount_minor": 19_000, "count": 2}],
            plan["packages"],
        )

    def test_xtr_offer_is_compared_against_real_topup_packages(self):
        report = analyze(
            premium_options=[
                {"users": 1, "months": 3, "currency": "XTR", "amount_minor": 300},
            ],
            topup_options=[
                {"stars": 100, "currency": "UAH", "amount_minor": 10_000},
            ],
        )

        estimate = report["xtr_acquisition_estimates"][0]["topup_estimates"]["UAH"]
        self.assertEqual(300, estimate["target_stars"])
        self.assertEqual(30_000, estimate["cost_minor"])
        self.assertEqual(0, estimate["overbuy_stars"])

    def test_native_direct_offer_can_be_compared_with_owner_observed_baseline(self):
        report = analyze(
            premium_options=[
                {"users": 1, "months": 3, "currency": "UAH", "amount_minor": 47_900},
                {"users": 1, "months": 6, "currency": "UAH", "amount_minor": 65_900},
            ],
            topup_options=[],
            baseline_currency="UAH",
            baseline_minor=49_900,
            baseline_months=3,
        )

        match = report["baseline_comparison"]["matching_offers"][0]
        self.assertTrue(match["below_baseline"])
        self.assertEqual(-2_000, match["delta_minor"])

    def test_multi_user_offer_is_not_mislabeled_as_direct_gift(self):
        report = analyze(
            premium_options=[
                {"users": 5, "months": 3, "currency": "XTR", "amount_minor": 1_501},
            ],
            topup_options=[],
        )

        offer = report["premium_options"][0]
        self.assertEqual("multi_gift_candidate", offer["offer_kind"])
        self.assertEqual("1501/5", offer["unit_amount_minor"])

    def test_probe_source_contains_no_payment_or_invoice_submission_calls(self):
        source = (HERE / "probe.py").read_text(encoding="utf-8")

        for forbidden in (
            "SendPaymentFormRequest",
            "GetPaymentFormRequest",
            "InputInvoicePremiumGift",
            "LaunchPrepaidGiveawayRequest",
        ):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
