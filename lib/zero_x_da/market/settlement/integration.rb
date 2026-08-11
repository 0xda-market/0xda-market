# frozen_string_literal: true

require_relative "contracts"

module ZeroXDA
  module Market
    module Settlement
      module KernelIntegration
        def initialize(settlement: nil, **options)
          @settlement_provider = settlement && Core::Contracts.validate_settlement_provider!(settlement)
          super(**options)
        end

        def settlement_cost(quote)
          return Core::Contracts::CostResult.new(variable_fee_bps: 0, fixed_cost_usdt: 0) unless @settlement_provider

          result = @settlement_provider.cost(quote: quote)
          return result if result.is_a?(Core::Contracts::CostResult)

          raise Core::ProviderContractError.new("settlement cost returned an invalid result")
        rescue Core::ProviderFailure
          raise
        rescue StandardError => error
          raise Core::ProviderFailure.new(
            "settlement cost raised an unexpected error",
            code: "unhandled_settlement_error",
            retryable: false,
            details: { exception: error.class.name }
          )
        end

        def charge_settlement(order_id)
          return nil unless @settlement_provider

          order = find_order(order_id)
          result = @settlement_provider.charge(
            order: order,
            idempotency_key: "orders/#{order.id}/settlement"
          )
          unless result.is_a?(Core::Contracts::SettlementResult) || result.is_a?(Core::Contracts::PendingSettlement)
            raise Core::ProviderContractError.new("settlement charge returned an invalid result")
          end
          result
        end

        def verify_settlement(settlement)
          return nil unless @settlement_provider
          raise Core::Conflict.new("settlement is missing", code: "payment_required") unless settlement

          result = @settlement_provider.verify(settlement: settlement)
          unless result.is_a?(Core::Contracts::SettlementResult)
            raise Core::Conflict.new(
              "settlement is not complete",
              code: "payment_required",
              details: { settlement_id: settlement.id }
            )
          end
          result
        end

        # Providers with delayed reward availability can expose a durable
        # maturity time. Broker earnings use this boundary before becoming
        # payout-eligible. Providers without such a contract remain immediate.
        def settlement_funds_available_at(order_id)
          return nil unless @settlement_provider&.respond_to?(:funds_available_at)

          @settlement_provider.funds_available_at(order_id: order_id)
        end

        private

        def start_execution(id)
          if @settlement_provider
            order = find_order(id)
            if order.payment && order.payment["settlement_required"]
              settlement = @settlement_provider.respond_to?(:find_by_order) && @settlement_provider.find_by_order(order.id)
              verify_settlement(settlement)
            end
          end
          super
        end
      end
    end
  end
end

ZeroXDA::Market::Core::Kernel.prepend(ZeroXDA::Market::Settlement::KernelIntegration)
