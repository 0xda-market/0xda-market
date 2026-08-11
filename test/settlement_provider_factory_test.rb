# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/composition/settlement_provider_factory"
require "zero_x_da/market/settlement/memory_store"

class SettlementProviderFactoryTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    @store = ZeroXDA::Market::Settlement::MemoryStore.new
  end

  def test_telegram_stars_defaults_to_twenty_one_day_reward_hold
    providers = build(
      "MARKET_PAYMENT_PROVIDER" => "telegram_stars",
      "TELEGRAM_STARS_USDT_PER_STAR" => "0.013"
    )

    assert_equal "telegram_stars", providers.primary.key
    assert_equal 21 * 24 * 60 * 60, providers.primary.funds_hold_seconds
    assert_same providers.primary, providers.payment_terms
  end

  def test_telegram_stars_reward_hold_cannot_be_configured_below_twenty_one_days
    error = assert_raises(RuntimeError) do
      build(
        "MARKET_PAYMENT_PROVIDER" => "telegram_stars",
        "TELEGRAM_STARS_USDT_PER_STAR" => "0.013",
        "TELEGRAM_STARS_REWARD_HOLD_SECONDS" => "86400"
      )
    end

    assert_match(/at least 21 days/, error.message)
  end

  private

  def build(values)
    env = {
      "MARKETPLACE_VARIABLE_FEE_BPS" => "0",
      "MARKETPLACE_FIXED_COST_USDT" => "0"
    }.merge(values)
    ZeroXDA::Market::Composition::SettlementProviderFactory.build(
      key: env.fetch("MARKET_PAYMENT_PROVIDER", ""),
      env: env,
      clock: @clock,
      store: @store,
      operator_token: nil
    )
  end
end
