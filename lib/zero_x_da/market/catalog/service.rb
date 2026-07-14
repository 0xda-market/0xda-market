# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "product"

module ZeroXDA
  module Market
    module Catalog
      class Service
        def initialize(store:)
          @store = store
        end

        def products
          @store.list_products(status: "active")
        end

        def find_product(sku)
          @store.find_product(sku.to_s) || raise(Core::NotFound.new("product", sku))
        end
      end
    end
  end
end
