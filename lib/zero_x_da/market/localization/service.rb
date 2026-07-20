# frozen_string_literal: true

require "bigdecimal"
require_relative "fx_rate"
require_relative "locale"

module ZeroXDA
  module Market
    module Localization
      class Service
        BASE_CURRENCY = "USDT"
        DEFAULT_LOCALE = "en_US"
        LANGUAGE_LOCALES = {
          "en" => "en_US",
          "uk" => "uk_UA"
        }.freeze
        DISPLAY_SCALE = 2

        def initialize(fx_store:)
          @fx_store = fx_store
        end

        # Unsupported languages fall back to the default instead of failing:
        # the language code comes from Telegram clients and must never break
        # a flow.
        def resolve(language_code: nil, currency: nil)
          Locale.new(
            code: locale_for(language_code),
            currency: normalize_currency(currency)
          )
        end

        def locale_for(language_code)
          base = language_code.to_s.downcase[/\A[a-z]{2}/]
          LANGUAGE_LOCALES.fetch(base, DEFAULT_LOCALE)
        end

        def convert(amount_usdt:, currency:)
          normalized = normalize_currency(currency)
          amount = amount_usdt.is_a?(BigDecimal) ? amount_usdt : BigDecimal(amount_usdt.to_s)
          return amount if normalized == BASE_CURRENCY

          rate = @fx_store.fx_rate(normalized)
          raise ArgumentError, "currency is not supported: #{normalized}" unless rate

          (amount / rate.usdt_per_unit).round(DISPLAY_SCALE)
        end

        def supported_currency?(currency)
          normalized = normalize_currency(currency)
          normalized == BASE_CURRENCY || !@fx_store.fx_rate(normalized).nil?
        end

        # The real buy-side rate: how many USDT we pay for one unit of the
        # currency when acquiring the product quantity. Set by admins for now;
        # the core pricing engine becomes the writer later without any
        # interface change.
        def set_rate(currency:, usdt_per_unit:, updated_at: Time.now.utc)
          normalized = normalize_currency(currency)
          if normalized == BASE_CURRENCY
            raise ArgumentError, "base currency rate is fixed at 1"
          end

          @fx_store.upsert_fx_rate(
            FxRate.new(
              currency: normalized,
              usdt_per_unit: usdt_per_unit,
              updated_at: updated_at
            )
          )
        end

        def rates
          @fx_store.fx_rates
        end

        def upsert_fx_rate(rate)
          @fx_store.upsert_fx_rate(rate)
        end

        private

        def normalize_currency(currency)
          value = currency.to_s.strip.upcase
          value.empty? ? BASE_CURRENCY : value
        end
      end
    end
  end
end
