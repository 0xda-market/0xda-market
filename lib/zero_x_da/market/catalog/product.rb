# frozen_string_literal: true

require "bigdecimal"
require_relative "../core/records"

module ZeroXDA
  module Market
    module Catalog
      class Product
        SKU_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,59}\z/
        LOCALE_PATTERN = /\A[a-z]{2}_[A-Z]{2}\z/
        STATUSES = %w[active inactive].freeze

        attr_reader :sku,
                    :short_name,
                    :name,
                    :button_label,
                    :locale,
                    :metadata,
                    :status,
                    :position,
                    :current_price_usdt,
                    :price_updated_at,
                    :price_updated_by_user_id,
                    :updated_by_user_id,
                    :created_at,
                    :updated_at,
                    :version

        def initialize(
          sku:,
          name:,
          button_label:,
          short_name: nil,
          locale: "en_US",
          metadata: {},
          status: "active",
          position:,
          current_price_usdt: nil,
          price_updated_at: nil,
          price_updated_by_user_id: nil,
          updated_by_user_id: nil,
          created_at:,
          updated_at: created_at,
          version: 0
        )
          @sku = string(sku, field: "sku", maximum_length: 60)
          raise ArgumentError, "sku is invalid" unless SKU_PATTERN.match?(@sku)
          @short_name = string(short_name || button_label, field: "short_name", maximum_length: 64)
          @name = string(name, field: "name", maximum_length: 160)
          @button_label = string(button_label, field: "button_label", maximum_length: 64)
          @locale = string(locale, field: "locale", maximum_length: 16)
          raise ArgumentError, "product locale is invalid" unless LOCALE_PATTERN.match?(@locale)
          raise ArgumentError, "product status is invalid" unless STATUSES.include?(status)

          @metadata = Core::RecordSupport.document(metadata, field: "metadata")
          @status = status.dup.freeze
          @position = Core::RecordSupport.non_negative_integer(position, field: "position")
          @current_price_usdt = optional_decimal(current_price_usdt)
          @price_updated_at = optional_time(price_updated_at, field: "price_updated_at")
          @price_updated_by_user_id = optional_identifier(
            price_updated_by_user_id,
            field: "price_updated_by_user_id"
          )
          @updated_by_user_id = optional_identifier(updated_by_user_id, field: "updated_by_user_id")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        private

        def optional_decimal(value)
          return nil if value.nil?

          amount = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
          raise ArgumentError, "current_price_usdt must be positive" unless amount.finite? && amount.positive?

          amount.round(6)
        rescue ArgumentError
          raise ArgumentError, "current_price_usdt must be a positive number"
        end

        def optional_time(value, field:)
          value && Core::RecordSupport.time(value, field: field)
        end

        def optional_identifier(value, field:)
          value && Core::RecordSupport.identifier(value, field: field)
        end

        def string(value, field:, maximum_length:)
          unless value.is_a?(String) && !value.empty?
            raise ArgumentError, "#{field} must be a non-empty string"
          end

          encoded = value.encode(Encoding::UTF_8)
          raise ArgumentError, "#{field} is too long" if encoded.length > maximum_length

          encoded.freeze
        rescue EncodingError
          raise ArgumentError, "#{field} contains invalid UTF-8"
        end
      end
    end
  end
end
