# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module Pricing
      class Price
        SOURCES = %w[admin core].freeze
        MAX_AMOUNT = BigDecimal("1000000000")

        attr_reader :sku,
                    :amount_usdt,
                    :source,
                    :set_by_user_id,
                    :created_at

        def initialize(
          sku:,
          amount_usdt:,
          source:,
          created_at:,
          set_by_user_id: nil
        )
          @sku = non_empty_string(sku, field: "sku")
          @amount_usdt = decimal(amount_usdt)
          raise ArgumentError, "price source is invalid" unless SOURCES.include?(source)

          @source = source.dup.freeze
          @set_by_user_id = optional_string(
            set_by_user_id,
            field: "set_by_user_id"
          )
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          freeze
        end

        private

        def decimal(value)
          amount = case value
                   when BigDecimal then value
                   when Integer then BigDecimal(value)
                   when String then parse_decimal(value)
                   when Numeric then BigDecimal(value.to_s)
                   else raise ArgumentError, "amount_usdt must be a number"
                   end
          unless amount.finite? && amount.positive?
            raise ArgumentError, "amount_usdt must be positive"
          end
          raise ArgumentError, "amount_usdt is too large" if amount > MAX_AMOUNT

          amount.round(6)
        end

        def parse_decimal(value)
          BigDecimal(value)
        rescue ArgumentError
          raise ArgumentError, "amount_usdt must be a number"
        end

        def non_empty_string(value, field:)
          unless value.is_a?(String) && !value.empty?
            raise ArgumentError, "#{field} must be a non-empty string"
          end

          value.dup.freeze
        end

        def optional_string(value, field:)
          return nil if value.nil?

          string = value.to_s
          raise ArgumentError, "#{field} is too long" if string.bytesize > 128

          string.empty? ? nil : string.freeze
        end
      end
    end
  end
end
