# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Payments
      # Converts the canonical market amount into an integer-denominated
      # provider amount using an explicit market-owned valuation. The adapter
      # that speaks to the payment provider remains responsible for transport
      # and provider authentication.
      class FixedRateIntegerTerms
        attr_reader :provider_key, :currency, :usdt_per_unit, :allowed_skus

        def initialize(provider_key:, currency:, usdt_per_unit:, allowed_skus: nil)
          @provider_key = Core::RecordSupport.identifier(provider_key.to_s, field: "payment provider key")
          @currency = Core::RecordSupport.identifier(currency.to_s.upcase, field: "payment currency")
          @usdt_per_unit = positive_decimal(usdt_per_unit, "usdt_per_unit")
          @allowed_skus = normalize_skus(allowed_skus)
        end

        def quote(amount_usdt:, sku: nil)
          normalized_sku = sku && Core::RecordSupport.identifier(sku.to_s, field: "product sku")
          if @allowed_skus && !@allowed_skus.include?(normalized_sku)
            raise Core::Conflict.new(
              "payment method is unavailable for this product",
              code: "payment_method_unavailable",
              details: { sku: normalized_sku, provider: @provider_key }
            )
          end

          canonical = positive_decimal(amount_usdt, "amount_usdt")
          units = (canonical / @usdt_per_unit).ceil
          raise Core::ProviderContractError.new("payment provider amount must be positive") unless units.positive?

          Core::RecordSupport.document(
            {
              "provider" => @provider_key,
              "currency" => @currency,
              "amount" => units.to_s,
              "valuation" => {
                "amount_usdt" => canonical.to_s("F"),
                "usdt_per_unit" => @usdt_per_unit.to_s("F"),
                "rounded" => "ceiling"
              }
            },
            field: "payment provider terms"
          )
        end

        private

        def normalize_skus(values)
          return nil if values.nil?

          entries = Array(values).map do |value|
            Core::RecordSupport.identifier(value.to_s, field: "allowed product sku")
          end.uniq.freeze
          raise ArgumentError, "allowed_skus must not be empty" if entries.empty?

          entries
        end

        def positive_decimal(value, field)
          number = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError, "#{field} must be positive" unless number.finite? && number.positive?

          number
        rescue ArgumentError
          raise ArgumentError, "#{field} must be a finite positive decimal"
        end
      end
    end
  end
end
