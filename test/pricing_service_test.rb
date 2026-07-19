# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../lib/zero_x_da/market/core/contracts"
require_relative "../lib/zero_x_da/market/pricing/memory_store"
require_relative "../lib/zero_x_da/market/pricing/service"

module ZeroXDA
  module Market
    module Pricing
      class ServiceTest < Minitest::Test
        FakeProduct = Struct.new(:sku, keyword_init: true)

        class FakeCatalog
          def initialize(skus)
            @skus = skus
          end

          def products(locale: "en_US")
            @skus.map { |sku| FakeProduct.new(sku: sku) }
          end

          def find_product(sku, locale: "en_US")
            unless @skus.include?(sku.to_s)
              raise Core::NotFound.new("product", sku)
            end

            FakeProduct.new(sku: sku.to_s)
          end
        end

        def setup
          @now = Time.utc(2026, 7, 15, 8, 0, 0)
          @service = Service.new(
            store: MemoryStore.new,
            catalog: FakeCatalog.new(%w[premium_3m stars_500]),
            clock: -> { @now }
          )
        end

        def test_apply_price_stores_latest_price
          @service.apply_price(
            sku: "premium_3m",
            amount_usdt: "12.50",
            set_by_user_id: "user-42"
          )
          price = @service.current_price("premium_3m")
          assert_equal BigDecimal("12.5"), price.amount_usdt
          assert_equal "admin", price.source
          assert_equal "user-42", price.set_by_user_id
        end

        def test_latest_application_wins
          @service.apply_price(sku: "premium_3m", amount_usdt: "12.50")
          @service.apply_price(sku: "premium_3m", amount_usdt: "11.90")
          assert_equal BigDecimal("11.9"), @service.current_price("premium_3m").amount_usdt
        end

        def test_apply_prices_rejects_unknown_sku_without_partial_apply
          assert_raises(Core::NotFound) do
            @service.apply_prices(
              [
                { "sku" => "premium_3m", "amount_usdt" => "12.50" },
                { "sku" => "missing", "amount_usdt" => "1.00" }
              ]
            )
          end
          assert_nil @service.current_price("premium_3m")
        end

        def test_rejects_non_positive_amount
          assert_raises(ArgumentError) do
            @service.apply_price(sku: "premium_3m", amount_usdt: "0")
          end
        end

        def test_proposal_separates_current_and_previous_day_prices
          @now = Time.utc(2026, 7, 14, 9, 0, 0)
          @service.apply_price(sku: "premium_3m", amount_usdt: "12.10")
          @now = Time.utc(2026, 7, 15, 7, 30, 0)
          @service.apply_price(sku: "premium_3m", amount_usdt: "12.50")

          proposal = @service.proposal(now: @now)
          entry = proposal.find { |item| item.fetch(:product).sku == "premium_3m" }
          assert_equal BigDecimal("12.5"), entry.fetch(:current).amount_usdt
          assert_equal BigDecimal("12.1"), entry.fetch(:previous).amount_usdt

          untouched = proposal.find { |item| item.fetch(:product).sku == "stars_500" }
          assert_nil untouched.fetch(:current)
          assert_nil untouched.fetch(:previous)
        end
      end
    end
  end
end
