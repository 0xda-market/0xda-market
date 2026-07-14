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

        def list_products(status:)
          @monitor.synchronize do
            @products.values
                     .select { |product| product.status == status }
                     .sort_by { |product| [product.position, product.sku] }
          end
        end

        def find_product(sku)
          @monitor.synchronize { @products[sku.to_s] }
        end
      end
    end
  end
end
