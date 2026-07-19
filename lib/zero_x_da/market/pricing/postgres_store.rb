# frozen_string_literal: true

require "bigdecimal"
require "sequel"
require_relative "price"

module ZeroXDA
  module Market
    module Pricing
      class PostgresStore
        def initialize(database:)
          @prices = database.connection[Sequel.qualify(:market, :product_prices)]
        end

        def append_price(price)
          @prices.insert(
            sku: price.sku,
            amount_usdt: price.amount_usdt,
            source: price.source,
            set_by_user_id: price.set_by_user_id,
            created_at: price.created_at
          )
          price
        end

        def latest_price(sku, before: nil)
          row = scope(before)
            .where(sku: sku.to_s)
            .order(Sequel.desc(:created_at), Sequel.desc(:id))
            .first
          row && deserialize(row)
        end

        def latest_prices(before: nil)
          rows = scope(before)
            .distinct(:sku)
            .order(:sku, Sequel.desc(:created_at), Sequel.desc(:id))
            .all
          rows.each_with_object({}) do |row, selected|
            selected[row.fetch(:sku)] = deserialize(row)
          end
        end

        private

        def scope(before)
          before ? @prices.where { created_at < before } : @prices
        end

        def deserialize(row)
          Price.new(
            sku: row.fetch(:sku),
            amount_usdt: BigDecimal(row.fetch(:amount_usdt).to_s),
            source: row.fetch(:source),
            set_by_user_id: row.fetch(:set_by_user_id),
            created_at: row.fetch(:created_at)
          )
        end
      end
    end
  end
end
