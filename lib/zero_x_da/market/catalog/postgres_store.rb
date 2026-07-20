# frozen_string_literal: true

require "sequel"
require_relative "product"

module ZeroXDA
  module Market
    module Catalog
      class PostgresStore
        DEFAULT_LOCALE = "en_US"
        SUPPORTED_LOCALES = %w[en_US uk_UA].freeze

        def initialize(database:)
          @products = database.connection[Sequel.qualify(:market, :products)]
          @localizations = database.connection[
            Sequel.qualify(:market, :product_localizations)
          ]
        end

        # Defaults to the sellable catalog (marketable: true) to match the
        # legacy "list_products returns what you can sell" behavior. Pass
        # marketable: false for currencies, or nil for both.
        def list_products(status:, locale: DEFAULT_LOCALE, marketable: true)
          locale = normalize_locale(locale)
          scope = @products.where(status: status)
          scope = scope.where(marketable: marketable) unless marketable.nil?
          rows = scope.order(:position, :sku).all
          translations = translations_for(rows.map { |row| row.fetch(:sku) }, locale)
          rows.map do |row|
            deserialize(row, locale: locale, translation: translations.fetch(row.fetch(:sku)))
          end
        end

        def find_product(sku, locale: DEFAULT_LOCALE)
          locale = normalize_locale(locale)
          row = @products.where(sku: sku.to_s).first
          return nil unless row

          translation = translations_for([row.fetch(:sku)], locale).fetch(row.fetch(:sku))
          deserialize(row, locale: locale, translation: translation)
        end

        private

        def translations_for(skus, locale)
          rows = @localizations.where(
            product_sku: skus,
            locale: [locale, DEFAULT_LOCALE]
          ).all
          grouped = rows.group_by { |row| row.fetch(:product_sku) }
          skus.to_h do |sku|
            candidates = grouped.fetch(sku, [])
            requested = candidates.find { |row| row.fetch(:locale) == locale }
            fallback = candidates.find { |row| row.fetch(:locale) == DEFAULT_LOCALE }
            [sku, requested || fallback || {}]
          end
        end

        def deserialize(row, locale:, translation:)
          short_name = row.fetch(:short_name)
          Product.new(
            sku: row.fetch(:sku),
            short_name: short_name,
            name: translation.fetch(:full_name, short_name),
            button_label: translation.fetch(:button_label, short_name),
            locale: translation.fetch(:locale, DEFAULT_LOCALE),
            metadata: document(row.fetch(:metadata)),
            status: row.fetch(:status),
            position: row.fetch(:position),
            marketable: row.fetch(:marketable, true),
            current_price_usdt: row.fetch(:current_price_usdt),
            price_updated_at: row.fetch(:price_updated_at),
            price_updated_by_user_id: row.fetch(:price_updated_by_user_id),
            updated_by_user_id: row.fetch(:updated_by_user_id),
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            version: row.fetch(:version)
          )
        end

        def normalize_locale(value)
          normalized = value.to_s.tr("-", "_")
          return "uk_UA" if normalized.downcase.start_with?("uk")

          SUPPORTED_LOCALES.include?(normalized) ? normalized : DEFAULT_LOCALE
        end

        def document(value)
          value.respond_to?(:to_hash) ? value.to_hash : value
        end
      end
    end
  end
end
