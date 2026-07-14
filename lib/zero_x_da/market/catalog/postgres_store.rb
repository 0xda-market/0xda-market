# frozen_string_literal: true

require "sequel"
require_relative "product"

module ZeroXDA
  module Market
    module Catalog
      class PostgresStore
        def initialize(database:)
          @products = database.connection[Sequel.qualify(:market, :products)]
        end

        def list_products(status:)
          @products.where(status: status).order(:position, :sku).all.map do |row|
            deserialize(row)
          end
        end

        def find_product(sku)
          row = @products.where(sku: sku.to_s).first
          row && deserialize(row)
        end

        private

        def deserialize(row)
          Product.new(
            sku: row.fetch(:sku),
            name: row.fetch(:name),
            button_label: row.fetch(:button_label),
            metadata: document(row.fetch(:metadata)),
            status: row.fetch(:status),
            position: row.fetch(:position),
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            version: row.fetch(:version)
          )
        end

        def document(value)
          value.respond_to?(:to_hash) ? value.to_hash : value
        end
      end
    end
  end
end
