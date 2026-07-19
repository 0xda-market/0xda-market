# frozen_string_literal: true

require_relative "fx_rate"

module ZeroXDA
  module Market
    module Localization
      class Locale
        SUPPORTED = %w[en_US uk_UA].freeze

        attr_reader :code, :language, :currency

        def initialize(code:, currency:)
          unless SUPPORTED.include?(code)
            raise ArgumentError, "locale is not supported"
          end
          unless FxRate::CURRENCY_PATTERN.match?(currency.to_s)
            raise ArgumentError, "currency code is invalid"
          end

          @code = code.dup.freeze
          @language = code.split("_", 2).first.freeze
          @currency = currency.to_s.freeze
          freeze
        end
      end
    end
  end
end
