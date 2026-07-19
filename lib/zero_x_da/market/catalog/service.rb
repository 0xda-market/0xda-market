# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "product"

module ZeroXDA
  module Market
    module Catalog
      class Service
        DEFAULT_LOCALE = "en_US"

        def initialize(store:)
          @store = store
        end

        def products(locale: DEFAULT_LOCALE)
          @store.list_products(status: "active", locale: locale)
        end

        def find_product(sku, locale: DEFAULT_LOCALE)
          @store.find_product(sku.to_s, locale: locale) || raise(Core::NotFound.new("product", sku))
        end
      end
    end
  end
end
