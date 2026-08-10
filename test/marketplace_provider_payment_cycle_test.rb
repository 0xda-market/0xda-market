# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/listings/memory_store"
require "zero_x_da/market/listings/service"
require "zero_x_da/market/marketplace/service"
require "zero_x_da/market/pricing/memory_store"
require "zero_x_da/market/pricing/profitability_policy"
require "zero_x_da/market/pricing/service"
require "zero_x_da/market/settlement/integer_unit_provider"
require "zero_x_da/market/settlement/integration"

class MarketplaceProviderPaymentCycleTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    users = ZeroXDA::Market::Identity::MemoryStore.new
    identity = ZeroXDA::Market::Identity::Service.new(
      store: users,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @broker = identity.authenticate(provider: "telegram", provider_user_id: "77", role: "broker").user
    @client = identity.authenticate(provider: "telegram", provider_user_id: "78").user
    @other_client = identity.authenticate(provider: "telegram", provider_user_id: "79").user

    product = ZeroXDA::Market::Catalog::Product.new(
      sku: "premium_3m",
      short_name: "Premium 3m",
      name: "Telegram Premium 3 months",
      button_label: "Premium 3m",
      marketable: true,
      position: 1,
      created_at: @clock.call
    )
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: [product]),
      clock: @clock
    )
    pricing = ZeroXDA::Market::Pricing::Service.new(
      store: ZeroXDA::Market::Pricing::MemoryStore.new,
      catalog: catalog,
      clock: @clock
    )
    pricing.apply_price(sku: "premium_3m", amount_usdt: "12.50")
    profitability = ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(
      minimum_margin_bps: 1_000,
      supply_buffer_bps: 0,
      variable_fee_bps: 0,
      fixed_cost_usdt: 0
    )
    listings = ZeroXDA::Market::Listings::Service.new(
      store: ZeroXDA::Market::Listings::MemoryStore.new,
      users: users,
      catalog: catalog,
      profitability: profitability,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    listings.create(
      actor_user_id: @broker.id,
      sku: "premium_3m",
      quantity: "2",
      price_amount: "9.25",
      currency: "USDT"
    )

    @settlement = ZeroXDA::Market::Settlement::IntegerUnitProvider.new(
      key: "telegram_stars",
      currency: "XTR",
      usdt_per_unit: "0.013",
      allowed_skus: ["premium_3m"],
      clock: @clock
    )
    provider = TestProvider.new(clock: @clock, quote_ttl: 60)
    @kernel = ZeroXDA::Market::Core::Kernel.new(
      providers: { "manual.fulfillment" => provider },
      settlement: @settlement,
      store: ZeroXDA::Market::Adapters::MemoryStore.new,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @marketplace = ZeroXDA::Market::Marketplace::Service.new(
      kernel: @kernel,
      catalog: catalog,
      pricing: pricing,
      listings: listings,
      settlement_provider: @settlement,
      payment_terms_provider: @settlement
    )
  end

  def test_provider_payment_is_durable_customer_scoped_and_required_before_fulfillment
    quote = @marketplace.quote(
      customer_user_id: @client.id,
      sku: "premium_3m",
      quantity: 1
    )
    accepted = @marketplace.accept(
      customer_user_id: @client.id,
      quote_id: quote.quote.id
    )

    assert_equal "payment_pending", accepted.order.status
    assert_equal "pending", accepted.order.payment.fetch("status")
    assert_equal "telegram_stars", accepted.order.payment.dig("provider", "provider")
    assert_equal "XTR", accepted.order.payment.dig("provider", "currency")
    assert_equal "962", accepted.order.payment.dig("provider", "amount")
    assert_equal "pending", @settlement.find_by_order(accepted.order.id).state

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @marketplace.execute_order(
        customer_user_id: @client.id,
        order_id: accepted.order.id
      )
    end
    assert_equal "payment_required", error.code

    assert_raises(ZeroXDA::Market::Core::Forbidden) do
      @marketplace.confirm_customer_payment(
        customer_user_id: @other_client.id,
        order_id: accepted.order.id,
        reference: "charge-other",
        provider: "telegram_stars",
        amount: 962,
        currency: "XTR"
      )
    end

    mismatch = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @marketplace.confirm_customer_payment(
        customer_user_id: @client.id,
        order_id: accepted.order.id,
        reference: "charge-short",
        provider: "telegram_stars",
        amount: 961,
        currency: "XTR"
      )
    end
    assert_equal "payment_provider_mismatch", mismatch.code
    assert_equal "pending", @settlement.find_by_order(accepted.order.id).state

    paid = @marketplace.confirm_customer_payment(
      customer_user_id: @client.id,
      order_id: accepted.order.id,
      reference: "charge-1",
      provider: "telegram_stars",
      amount: 962,
      currency: "XTR",
      data: { "source" => "authoritative-provider-event" }
    )

    assert_equal "succeeded", paid.order.status
    assert_equal "confirmed", paid.order.payment.fetch("status")
    assert_equal "charge-1", paid.order.payment.fetch("reference")
    assert_equal "committed", paid.reservation.status
    settlement = @settlement.find_by_order(accepted.order.id)
    assert_equal "settled", settlement.state
    assert_equal "charge-1", settlement.external_reference

    repeated = @marketplace.confirm_customer_payment(
      customer_user_id: @client.id,
      order_id: accepted.order.id,
      reference: "charge-1",
      provider: "telegram_stars",
      amount: 962,
      currency: "XTR"
    )
    assert_equal paid.order.id, repeated.order.id

    duplicate = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @marketplace.confirm_customer_payment(
        customer_user_id: @client.id,
        order_id: accepted.order.id,
        reference: "charge-2",
        provider: "telegram_stars",
        amount: 962,
        currency: "XTR"
      )
    end
    assert_equal "payment_reference_mismatch", duplicate.code
  end
end
