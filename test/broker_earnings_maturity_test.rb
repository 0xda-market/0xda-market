# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/broker_earnings/earning"
require "zero_x_da/market/broker_earnings/memory_store"
require "zero_x_da/market/broker_earnings/service"

class BrokerEarningsMaturityTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    @store = ZeroXDA::Market::BrokerEarnings::MemoryStore.new
    @service = ZeroXDA::Market::BrokerEarnings::Service.new(
      store: @store,
      localization: nil,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @seller_id = "seller-1"
    earning = ZeroXDA::Market::BrokerEarnings::Earning.new(
      id: "earning-1",
      order_id: "order-1",
      reservation_id: "reservation-1",
      listing_id: "listing-1",
      seller_user_id: @seller_id,
      quantity: "1",
      ask_amount: "9.25",
      ask_currency: "USDT",
      payable_amount: "9.25",
      payable_currency: "USDT",
      created_at: @clock.call
    )
    @store.transaction { |store| store.insert(earning) }
    @service.save_payout_profile(
      actor_user_id: @seller_id,
      network: "TRON",
      destination: "TAddress",
      minimum_payout_amount: "0"
    )
  end

  def test_future_maturity_keeps_earning_pending_and_out_of_payouts_until_due
    maturity = @clock.call + (21 * 24 * 60 * 60)
    earning = @service.make_available(order_id: "order-1", not_before: maturity)

    assert_equal "pending", earning.state
    assert_equal maturity, earning.available_at

    # A retry from older/internal code that omits not_before must not shorten a
    # durable provider hold that was already recorded.
    retried = @service.make_available(order_id: "order-1")
    assert_equal "pending", retried.state
    assert_equal maturity, retried.available_at

    balance = @service.balance(actor_user_id: @seller_id)
    assert_equal BigDecimal("9.25"), balance.pending
    assert_equal BigDecimal("0"), balance.available

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @service.queue_payout(actor_user_id: @seller_id)
    end
    assert_equal "no_available_earnings", error.code

    @clock.advance(21 * 24 * 60 * 60)
    matured = @service.list(actor_user_id: @seller_id).fetch(0)
    assert_equal "available", matured.state
    assert_equal maturity, matured.available_at

    payout = @service.queue_payout(actor_user_id: @seller_id)
    assert_equal "queued", payout.state
    assert_equal BigDecimal("9.25"), payout.amount
  end
end
