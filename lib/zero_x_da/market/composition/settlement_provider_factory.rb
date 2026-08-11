# frozen_string_literal: true

require_relative "../pricing/profitability_policy"
require_relative "../settlement/manual_provider"
require_relative "../settlement/integer_unit_provider"

module ZeroXDA
  module Market
    module Composition
      SettlementProviders = Struct.new(:primary, :manual, :payment_terms, keyword_init: true)

      module SettlementProviderFactory
        module_function

        def build(key:, env:, clock:, store:, operator_token:)
          provider_key = key.to_s.strip
          common = {
            variable_fee_bps: Integer(env.fetch("MARKETPLACE_VARIABLE_FEE_BPS", Pricing::ProfitabilityPolicy::DEFAULT_VARIABLE_FEE_BPS.to_s)),
            fixed_cost_usdt: env.fetch("MARKETPLACE_FIXED_COST_USDT", Pricing::ProfitabilityPolicy::DEFAULT_FIXED_COST_USDT.to_s("F"))
          }

          if provider_key.empty?
            manual = build_manual(env: env, clock: clock, store: store, operator_token: operator_token, common: common)
            return SettlementProviders.new(primary: manual, manual: manual, payment_terms: nil)
          end

          payment_kind = env.fetch("MARKET_PAYMENT_KIND", "integer_unit").to_s.strip
          raise "MARKET_PAYMENT_KIND is unsupported" unless payment_kind == "integer_unit"

          provider = build_integer_unit(
            provider_key: provider_key,
            env: env,
            clock: clock,
            store: store,
            common: common
          )
          SettlementProviders.new(primary: provider, manual: nil, payment_terms: provider)
        end

        def build_integer_unit(provider_key:, env:, clock:, store:, common:)
          currency = required_value(env, "MARKET_PAYMENT_CURRENCY")
          rate = required_value(env, "MARKET_PAYMENT_USDT_PER_UNIT")
          skus = required_value(env, "MARKET_PAYMENT_SKUS").split(",").map(&:strip).reject(&:empty?).uniq
          raise "MARKET_PAYMENT_SKUS must contain at least one SKU" if skus.empty?

          Settlement::IntegerUnitProvider.new(
            key: provider_key,
            currency: currency,
            usdt_per_unit: rate,
            allowed_skus: skus,
            funds_hold_seconds: Integer(env.fetch("MARKET_PAYMENT_FUNDS_HOLD_SECONDS", "0")),
            clock: clock,
            store: store,
            **common
          )
        end

        def build_manual(env:, clock:, store:, operator_token:, common:)
          return nil if operator_token.to_s.empty?

          Settlement::ManualProvider.new(
            clock: clock,
            store: store,
            **common,
            tolerance_bps: Integer(env.fetch("MANUAL_SETTLEMENT_TOLERANCE_BPS", "0"))
          )
        end

        def required_value(env, name)
          value = env[name].to_s.strip
          raise "#{name} is required when MARKET_PAYMENT_PROVIDER is configured" if value.empty?

          value
        end
      end
    end
  end
end
