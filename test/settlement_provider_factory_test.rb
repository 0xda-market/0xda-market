# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/composition/settlement_provider_factory"
require "zero_x_da/market/settlement/memory_store"

class SettlementProviderFactoryTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    @store = ZeroXDA::Market::Settlement::MemoryStore.new
  end

  def test_builds_a_provider_neutral_integer_unit_payment_adapter
    providers = build(
      "MARKET_PAYMENT_PROVIDER" => "provider.example",
      "MARKET_PAYMENT_KIND" => "integer_unit",
      "MARKET_PAYMENT_CURRENCY" => "TOK",
      "MARKET_PAYMENT_USDT_PER_UNIT" => "0.25",
      "MARKET_PAYMENT_SKUS" => "sku_a,sku_b",
      "MARKET_PAYMENT_FUNDS_HOLD_SECONDS" => "3600"
    )

    assert_equal "provider.example", providers.primary.key
    assert_equal 3600, providers.primary.funds_hold_seconds
    assert_same providers.primary, providers.payment_terms
  end

  def test_requires_explicit_integer_unit_payment_configuration
    error = assert_raises(RuntimeError) do
      build(
        "MARKET_PAYMENT_PROVIDER" => "provider.example",
        "MARKET_PAYMENT_CURRENCY" => "TOK"
      )
    end

    assert_match(/MARKET_PAYMENT_USDT_PER_UNIT is required/, error.message)
  end

  def test_rejects_unsupported_payment_kind
    error = assert_raises(RuntimeError) do
      build(
        "MARKET_PAYMENT_PROVIDER" => "provider.example",
        "MARKET_PAYMENT_KIND" => "provider_specific"
      )
    end

    assert_equal "MARKET_PAYMENT_KIND is unsupported", error.message
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
