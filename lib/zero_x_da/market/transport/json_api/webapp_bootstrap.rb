# frozen_string_literal: true

require "digest"
require "json"
require "time"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        class EndpointHandler
          WEBAPP_BOOTSTRAP_SCHEMA_VERSION = 1

          # Returns the complete active sellable catalog in one response. The
          # browser owns pagination, search and filtering for the lifetime of
          # this immutable snapshot; checkout still revalidates through core.
          def webapp_bootstrap(request)
            currency = @request_parser.requested_currency(request)
            locale = @request_parser.requested_locale(request)
            products = @catalog.products(locale: locale)
            prices = @pricing ? @pricing.current_prices : {}
            executable_skus = available_executable_skus(prices)
            listed_skus = if @listings&.respond_to?(:available_skus)
                            @listings.available_skus.to_h { |sku| [sku, true] }
                          elsif executable_skus
                            executable_skus
                          end
            data = products.map do |product|
              price = prices[product.sku]
              listed = listed_skus.nil? || listed_skus.key?(product.sku)
              amount_usdt = effective_client_price_amount(
                price,
                sku: product.sku,
                executable_skus: executable_skus
              )
              available = listed && !amount_usdt.nil?
              visible_amount_usdt = amount_usdt || (price&.amount_usdt if listed)
              present_webapp_product(
                product,
                price: visible_amount_usdt && price,
                amount_usdt: visible_amount_usdt,
                currency: currency,
                listed: listed,
                available: available
              )
            end
            snapshot_id = Digest::SHA256.hexdigest(JSON.generate(data))

            json_response(
              200,
              {
                "data" => data,
                "meta" => {
                  "schema_version" => WEBAPP_BOOTSTRAP_SCHEMA_VERSION,
                  "snapshot_id" => snapshot_id,
                  "generated_at" => Time.now.utc.iso8601(6),
                  "count" => data.length,
                  "listed_count" => data.count { |resource| resource.dig("attributes", "listed") },
                  "available_count" => data.count { |resource| resource.dig("attributes", "available") },
                  "complete" => true,
                  "pagination" => "client",
                  "currency" => currency,
                  "locale" => locale
                }
              }
            )
          end

          private

          def present_webapp_product(product, price:, amount_usdt:, currency:, listed:, available:)
            resource = present_product(product)
            attributes = resource.fetch("attributes").dup
            attributes.delete("updated_by_user_id")
            attributes.delete("price_updated_by_user_id")
            attributes["listed"] = listed
            attributes["available"] = available
            attributes["price"] = price && public_webapp_price(
              price,
              amount_usdt: amount_usdt,
              currency: currency
            )
            resource.merge("attributes" => attributes)
          end

          def public_webapp_price(price, amount_usdt:, currency:)
            presented = present_effective_client_price(
              price,
              amount_usdt: amount_usdt,
              currency: currency
            )
            if @localization
              presented = presented.merge(
                "amount" => decimal_string(
                  @localization.present_client_price(amount_usdt: amount_usdt, currency: currency)
                )
              )
            end

            presented.reject do |key, _value|
              key == "edited_by_user_id"
            end
          end
        end
      end
    end
  end
end
