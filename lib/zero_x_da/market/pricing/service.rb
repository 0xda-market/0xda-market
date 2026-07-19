# frozen_string_literal: true

require_relative "price"

module ZeroXDA
  module Market
    module Pricing
      class Service
        def initialize(store:, catalog:, clock: -> { Time.now.utc })
          @store = store
          @catalog = catalog
          @clock = clock
        end

        def apply_price(sku:, amount_usdt:, source: "admin", set_by_user_id: nil)
          apply_prices(
            [{ "sku" => sku, "amount_usdt" => amount_usdt }],
            source: source,
            set_by_user_id: set_by_user_id
          ).first
        end

        # Validates every entry against the catalog before appending anything,
        # so a bulk application is not partially applied on validation errors.
        def apply_prices(entries, source: "admin", set_by_user_id: nil)
          unless entries.is_a?(Array) && !entries.empty?
            raise ArgumentError, "prices must be a non-empty array"
          end

          now = current_time
          prices = entries.map do |entry|
            entry = normalize_entry(entry)
            product = @catalog.find_product(entry.fetch("sku"))
            Price.new(
              sku: product.sku,
              amount_usdt: entry.fetch("amount_usdt"),
              source: source,
              set_by_user_id: set_by_user_id,
              created_at: now
            )
          end
          prices.map { |price| @store.append_price(price) }
        end

        def current_prices
          @store.latest_prices
        end

        def current_price(sku)
          @store.latest_price(sku)
        end

        # Daily application data: for each active product, the current price
        # (which stays in effect until a new application is submitted) and the
        # latest price before the start of the current day ("yesterday's").
        def proposal(now: current_time, locale: "en_US")
          day_start = Time.utc(now.year, now.month, now.day)
          current = @store.latest_prices
          previous = @store.latest_prices(before: day_start)
          @catalog.products(locale: locale).map do |product|
            {
              product: product,
              current: current[product.sku],
              previous: previous[product.sku]
            }
          end
        end

        private

        def normalize_entry(entry)
          raise ArgumentError, "price entry must be an object" unless entry.respond_to?(:to_h)

          entry.to_h.transform_keys(&:to_s)
        end

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
