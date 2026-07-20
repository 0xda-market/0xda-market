# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "time"
require_relative "../lib/zero_x_da/market/localization/memory_store"
require_relative "../lib/zero_x_da/market/localization/service"

module ZeroXDA
  module Market
    module Localization
      class ServiceTest < Minitest::Test
        def setup
          @now = Time.utc(2026, 7, 15, 8, 0, 0)
          @service = Service.new(fx_store: MemoryStore.new(clock: -> { @now }))
        end

        def test_locale_for_maps_known_languages
          assert_equal "en_US", @service.locale_for("en")
          assert_equal "uk_UA", @service.locale_for("uk-UA")
        end

        def test_locale_for_falls_back_to_default
          assert_equal Service::DEFAULT_LOCALE, @service.locale_for("fr")
          assert_equal Service::DEFAULT_LOCALE, @service.locale_for(nil)
        end

        def test_convert_returns_base_amount_unchanged
          amount = @service.convert(amount_usdt: "12.50", currency: "USDT")
          assert_equal BigDecimal("12.5"), amount
        end

        def test_convert_uses_buy_side_rate
          @service.set_rate(currency: "EUR", usdt_per_unit: "1.16", updated_at: @now)
          amount = @service.convert(amount_usdt: "11.60", currency: "EUR")
          assert_equal BigDecimal("10"), amount
        end

        def test_convert_rejects_unsupported_currency
          assert_raises(ArgumentError) do
            @service.convert(amount_usdt: "10", currency: "EUR")
          end
        end

        def test_base_currency_rate_is_fixed
          assert_raises(ArgumentError) do
            @service.set_rate(currency: "USDT", usdt_per_unit: "2")
          end
        end

        def test_set_rate_upserts
          @service.set_rate(currency: "EUR", usdt_per_unit: "1.10", updated_at: @now)
          @service.set_rate(currency: "EUR", usdt_per_unit: "1.20", updated_at: @now)
          currencies = @service.rates.map(&:currency)
          assert_equal %w[EUR USDT], currencies
          assert_equal BigDecimal("1.2"), @service.rates.first.usdt_per_unit
        end
      end
    end
  end
end
