# frozen_string_literal: true

require_relative "../pricing/profitability_policy"
require_relative "../settlement/manual_provider"
require_relative "../settlement/integer_unit_provider"

module ZeroXDA
  module Market
    module Composition
      SettlementProviders = Struct.new(:primary, :manual, :payment_terms, keyword_init: true)

      module SettlementProviderFactory
        TELEGRAM_STARS_MINIMUM_REWARD_HOLD_SECONDS = 21 * 24 * 60 * 60

        module_function

        def build(key:, env:, clock:, store:, operator_token:)
          provider_key = key.to_s.strip
          common = {
            variable_fee_bps: Integer(env.fetch("MARKETPLACE_VARIABLE_FEE_BPS", Pricing::ProfitabilityPolicy::DEFAULT_VARIABLE_FEE_BPS.to_s)),
            fixed_cost_usdt: env.fetch("MARKETPLACE_FIXED_COST_USDT", Pricing::ProfitabilityPolicy::DEFAULT_FIXED_COST_USDT.to_s("F"))
          }

          case provider_key
          when ""
            manual = build_manual(env: env, clock: clock, store: store, operator_token: operator_token, common: common)
            SettlementProviders.new(primary: manual, manual: manual, payment_terms: nil)
          when "telegram_stars"
            rate = env["TELEGRAM_STARS_USDT_PER_STAR"].to_s.strip
            raise "TELEGRAM_STARS_USDT_PER_STAR is required for telegram_stars payments" if rate.empty?

            skus = env.fetch(
              "TELEGRAM_STARS_PAYMENT_SKUS",
              "premium_3m,premium_6m,premium_9m"
            ).split(",").map(&:strip).reject(&:empty?).uniq
            raise "TELEGRAM_STARS_PAYMENT_SKUS must contain at least one SKU" if skus.empty?

            reward_hold_seconds = Integer(
              env.fetch(
                "TELEGRAM_STARS_REWARD_HOLD_SECONDS",
                TELEGRAM_STARS_MINIMUM_REWARD_HOLD_SECONDS.to_s
              )
            )
            if reward_hold_seconds < TELEGRAM_STARS_MINIMUM_REWARD_HOLD_SECONDS
              raise "TELEGRAM_STARS_REWARD_HOLD_SECONDS must be at least 21 days"
            end

            provider = Settlement::IntegerUnitProvider.new(
              key: "telegram_stars",
              currency: "XTR",
              usdt_per_unit: rate,
              allowed_skus: skus,
              funds_hold_seconds: reward_hold_seconds,
              clock: clock,
              store: store,
              **common
            )
            SettlementProviders.new(primary: provider, manual: nil, payment_terms: provider)
          else
            raise "MARKET_PAYMENT_PROVIDER is unsupported"
          end
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
      end
    end
  end
end
