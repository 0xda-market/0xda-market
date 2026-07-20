# frozen_string_literal: true

require "monitor"
require_relative "product"

module ZeroXDA
  module Market
    module Catalog
      class MemoryStore
        def initialize(products: [])
          @products = products.to_h { |product| [product.sku, product] }
          @monitor = Monitor.new
        end

        # Defaults to the sellable catalog (marketable: true) to match the
        # legacy "list_products returns what you can sell" behavior. Pass
        # marketable: false for currencies, or nil for both.
        def list_products(status:, locale: "en_US", marketable: true)
          @monitor.synchronize do
            @products.values
                     .select { |product| product.status == status }
                     .select { |product| marketable.nil? || product.marketable? == marketable }
                     .sort_by { |product| [product.position, product.sku] }
          end
        end

        def find_product(sku, locale: "en_US")
          @monitor.synchronize { @products[sku.to_s] }
        end
      end
    end
  end
end
