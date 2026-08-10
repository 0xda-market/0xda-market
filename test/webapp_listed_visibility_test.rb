# frozen_string_literal: true

require_relative "test_helper"
require "bigdecimal"
require "json"
require "rack/mock"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/transport/json_api"

class WebAppListedVisibilityTest < Minitest::Test
  Price = Struct.new(:amount_usdt, :source, :set_by_user_id, :created_at, keyword_init: true)

  class Catalog
    def initialize(product)
      @product = product
    end

    def products(locale:)
      [@product]
    end
  end

  class Pricing
    def initialize(price)
      @price = price
    end

    def current_prices
      { "premium_12m" => @price }
    end
  end

  class Listings
    def available_skus
      ["premium_12m"]
    end

    def executable_skus(client_unit_prices_usdt:)
      []
    end
  end

  class Localization
    def locale_for(value)
      value.to_s == "uk_UA" ? "uk_UA" : "en_US"
    end

    def supported_currency?(value)
      value == "USDT"
    end

    def convert(amount_usdt:, currency:)
      raise ArgumentError, "unsupported currency" unless currency == "USDT"

      amount_usdt
    end

    def present_client_price(amount_usdt:, currency:)
      convert(amount_usdt: amount_usdt, currency: currency)
    end
  end

  def test_keeps_a_listed_product_visible_without_an_executable_client_price
    now = Time.utc(2026, 8, 4, 20, 0, 0)
    product = ZeroXDA::Market::Catalog::Product.new(
      sku: "premium_12m",
      short_name: "Premium 12m",
      name: "Telegram Premium 12 months",
      button_label: "Premium 12 months",
      locale: "uk_UA",
      metadata: { "category" => "telegram-premium" },
      status: "active",
      position: 3,
      updated_by_user_id: "admin-1",
      price_updated_by_user_id: "admin-1",
      price_updated_at: now,
      created_at: now
    )
    price = Price.new(
      amount_usdt: BigDecimal("35"), source: "admin",
      set_by_user_id: "admin-1", created_at: now
    )
    api = ZeroXDA::Market::Transport::JSONAPI.new(
      kernel: Object.new,
      catalog: Catalog.new(product),
      pricing: Pricing.new(price),
      localization: Localization.new,
      listings: Listings.new
    )

    document = JSON.parse(
      Rack::MockRequest.new(api).get(
        "/v1/webapp/bootstrap?locale=uk_UA&currency=USDT"
      ).body
    )
    attributes = document.dig("data", 0, "attributes")

    assert_equal true, attributes.fetch("listed")
    assert_equal false, attributes.fetch("available")
    assert_equal "35.0", attributes.dig("price", "amount")
    assert_equal 1, document.dig("meta", "listed_count")
    assert_equal 0, document.dig("meta", "available_count")
  end
end
