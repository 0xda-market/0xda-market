# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"

class CatalogTest < Minitest::Test
  def setup
    @time = Time.utc(2026, 7, 14, 12, 0, 0)
  end

  def test_lists_only_active_products_in_catalog_position_order
    products = [
      product("btc", position: 3),
      product("hidden", position: 2, status: "inactive"),
      product("premium_3m", position: 1)
    ]
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: products)
    )

    assert_equal %w[premium_3m btc], catalog.products.map(&:sku)
  end

  def test_finds_a_product_by_sku
    expected = product("stars_500", position: 1)
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: [expected])
    )

    assert_same expected, catalog.find_product("stars_500")
  end

  def test_reports_an_unknown_product
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new
    )

    error = assert_raises(ZeroXDA::Market::Core::NotFound) do
      catalog.find_product("missing")
    end

    assert_equal "not_found", error.code
  end

  def test_validates_the_stable_sku
    error = assert_raises(ArgumentError) do
      product("Premium 3 months", position: 1)
    end

    assert_equal "sku is invalid", error.message
  end

  def test_limits_the_sku_to_telegram_callback_capacity
    error = assert_raises(ArgumentError) do
      product("a" * 61, position: 1)
    end

    assert_equal "sku is too long", error.message
  end

  private

  def product(sku, position:, status: "active")
    ZeroXDA::Market::Catalog::Product.new(
      sku: sku,
      name: sku,
      button_label: sku,
      metadata: { "source" => "test" },
      status: status,
      position: position,
      created_at: @time
    )
  end
end
