# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/settlement/integer_unit_provider"

class IntegerUnitSettlementTest < Minitest::Test
  Order = Struct.new(:id, :payment, keyword_init: true)

  def setup
    @clock = MutableClock.new
    @provider = ZeroXDA::Market::Settlement::IntegerUnitProvider.new(
      key: "telegram_stars",
      currency: "XTR",
      usdt_per_unit: "0.013",
      allowed_skus: %w[premium_3m premium_6m premium_9m],
      clock: @clock
    )
  end

  def test_quotes_integer_units_upward_and_restricts_products
    terms = @provider.quote(amount_usdt: "12.50", sku: "premium_3m")

    assert_equal "telegram_stars", terms.fetch("provider")
    assert_equal "XTR", terms.fetch("currency")
    assert_equal "962", terms.fetch("amount")
    assert_equal "12.5", terms.dig("valuation", "amount_usdt")
    assert_equal "0.013", terms.dig("valuation", "usdt_per_unit")
    assert_equal "ceiling", terms.dig("valuation", "rounded")

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.quote(amount_usdt: "12.50", sku: "stars_500")
    end
    assert_equal "payment_method_unavailable", error.code
  end

  def test_requires_exact_provider_evidence_and_is_idempotent
    terms = @provider.quote(amount_usdt: "12.50", sku: "premium_3m")
    order = Order.new(
      id: "order-1",
      payment: {
        "status" => "pending",
        "amount" => "12.50",
        "currency" => "USDT",
        "expires_at" => (@clock.call + 60).iso8601(6),
        "provider" => terms
      }
    )

    pending = @provider.charge(order: order, idempotency_key: "orders/order-1/settlement")
    assert_instance_of ZeroXDA::Market::Core::Contracts::PendingSettlement, pending
    assert_equal "pending", pending.data.fetch("state")

    mismatch = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.confirm(
        order_id: order.id,
        reference: "charge-0",
        provider: "telegram_stars",
        amount: 961,
        currency: "XTR"
      )
    end
    assert_equal "payment_provider_mismatch", mismatch.code

    settled = @provider.confirm(
      order_id: order.id,
      reference: "charge-1",
      provider: "telegram_stars",
      amount: 962,
      currency: "XTR",
      data: { "source" => "authoritative-provider-event" }
    )
    assert settled.settled?
    assert_equal "charge-1", settled.external_reference
    assert_equal BigDecimal("12.506"), settled.received_usdt

    repeated = @provider.confirm(
      order_id: order.id,
      reference: "charge-1",
      provider: "telegram_stars",
      amount: 962,
      currency: "XTR"
    )
    assert_equal settled.id, repeated.id

    duplicate_charge = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.confirm(
        order_id: order.id,
        reference: "charge-2",
        provider: "telegram_stars",
        amount: 962,
        currency: "XTR"
      )
    end
    assert_equal "payment_reference_mismatch", duplicate_charge.code
  end

  def test_expired_settlement_cannot_be_confirmed
    terms = @provider.quote(amount_usdt: "1", sku: "premium_3m")
    order = Order.new(
      id: "order-expired",
      payment: {
        "status" => "pending",
        "amount" => "1",
        "currency" => "USDT",
        "expires_at" => (@clock.call + 1).iso8601(6),
        "provider" => terms
      }
    )
    @provider.charge(order: order, idempotency_key: "orders/order-expired/settlement")
    @clock.advance(2)

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.confirm(
        order_id: order.id,
        reference: "charge-expired",
        provider: "telegram_stars",
        amount: 77,
        currency: "XTR"
      )
    end
    assert_equal "payment_expired", error.code
  end
end
