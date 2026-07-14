# frozen_string_literal: true

require_relative "../core/records"

module ZeroXDA
  module Market
    module Catalog
      class Product
        SKU_PATTERN = /\A[a-z0-9][a-z0-9_-]{0,59}\z/
        STATUSES = %w[active inactive].freeze

        attr_reader :sku,
                    :name,
                    :button_label,
                    :metadata,
                    :status,
                    :position,
                    :created_at,
                    :updated_at,
                    :version

        def initialize(
          sku:,
          name:,
          button_label:,
          metadata: {},
          status: "active",
          position:,
          created_at:,
          updated_at: created_at,
          version: 0
        )
          @sku = string(sku, field: "sku", maximum_length: 60)
          raise ArgumentError, "sku is invalid" unless SKU_PATTERN.match?(@sku)
          @name = string(name, field: "name", maximum_length: 160)
          @button_label = string(button_label, field: "button_label", maximum_length: 64)
          raise ArgumentError, "product status is invalid" unless STATUSES.include?(status)

          @metadata = Core::RecordSupport.document(metadata, field: "metadata")
          @status = status.dup.freeze
          @position = Core::RecordSupport.non_negative_integer(position, field: "position")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        private

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
