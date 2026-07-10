# frozen_string_literal: true

require_relative "contracts"

module ZeroXDA
  module Market
    module Core
      class Kernel
        def initialize(providers:, store:, clock:, id_generator:)
          @providers = providers.each_with_object({}) do |(capability, provider), copy|
            normalized = RecordSupport.capability(capability)
            copy[normalized] = Contracts.validate_provider!(provider)
          end.freeze
          @store = store
          @clock = clock
          @id_generator = id_generator
        end

        def create_intent(capability:, payload:, context: {})
          normalized = RecordSupport.capability(capability)
          provider_for(normalized)

          intent = Intent.new(
            id: next_id,
            capability: normalized,
            payload: payload,
            context: context,
            created_at: current_time
          )
          @store.insert(:intents, intent)
        end

        def find_intent(id)
          @store.fetch(:intents, id)
        end

        def quote_intent(id)
          intent = find_intent(id)
          provider = provider_for(intent.capability)
          result = invoke_quote(provider, intent)

          quote = Quote.new(
            id: next_id,
            intent_id: intent.id,
            provider_key: provider_key(provider),
            terms: result.terms,
            private_state: result.private_state,
            expires_at: result.expires_at,
            created_at: current_time
          )
          @store.insert(:quotes, quote)
        end

        def find_quote(id)
          @store.fetch(:quotes, id)
        end

        def accept_quote(id)
          now = current_time

          @store.transaction do |store|
            quote = store.fetch(:quotes, id)
            order_id = order_id_for(quote)
            existing = store.find(:orders, order_id)
            next existing if existing

            raise QuoteExpired.new(quote.id) if quote.expired?(at: now)

            intent = store.fetch(:intents, quote.intent_id)
            order = Order.new(
              id: order_id,
              intent_id: intent.id,
              quote_id: quote.id,
              capability: intent.capability,
              provider_key: quote.provider_key,
              payload: intent.payload,
              context: intent.context,
              terms: quote.terms,
              private_state: quote.private_state,
              created_at: now
            )
            store.insert(:orders, order)
          end
        end

        def find_order(id)
          @store.fetch(:orders, id)
        end

        def execute_order(id)
          started = start_execution(id)
          return started if started.status == "succeeded"

          result = begin
            provider = provider_for(started.capability)
            ensure_provider_identity!(provider, started)
            execution = provider.execute(
              order: started,
              idempotency_key: "orders/#{started.id}/execute"
            )
            unless execution.is_a?(Contracts::ExecutionResult)
              raise ProviderContractError.new(
                "provider execution returned an invalid result"
              )
            end
            execution
          rescue ProviderFailure => error
            fail_execution(started, error)
            raise
          rescue StandardError => error
            wrapped = ProviderFailure.new(
              "provider execution raised an unexpected error",
              code: "unhandled_provider_error",
              retryable: false,
              details: { exception: error.class.name }
            )
            fail_execution(started, wrapped)
            raise wrapped
          end

          complete_execution(started, result)
        end

        def cancel_order(id)
          now = current_time

          @store.transaction do |store|
            order = store.fetch(:orders, id)
            next order if order.status == "cancelled"

            ensure_status!(order, allowed: ["accepted"], event: "cancel")
            cancelled = rebuild_order(
              order,
              status: "cancelled",
              updated_at: now,
              version: order.version + 1
            )
            store.replace(:orders, cancelled, expected_version: order.version)
          end
        end

        private

        def start_execution(id)
          now = current_time

          @store.transaction do |store|
            order = store.fetch(:orders, id)
            next order if order.status == "succeeded"

            retryable = order.status == "failed" && order.failure.fetch("retryable", false)
            unless order.status == "accepted" || retryable
              raise InvalidTransition.new(
                resource: "order",
                id: order.id,
                from: order.status,
                event: "execute"
              )
            end

            started = rebuild_order(
              order,
              status: "processing",
              attempts: order.attempts + 1,
              result: nil,
              failure: nil,
              updated_at: now,
              version: order.version + 1
            )
            store.replace(:orders, started, expected_version: order.version)
          end
        end

        def complete_execution(started, execution)
          now = current_time

          @store.transaction do |store|
            current = store.fetch(:orders, started.id)
            ensure_same_attempt!(started, current)

            completed = rebuild_order(
              current,
              status: "succeeded",
              result: {
                reference: execution.reference,
                data: execution.data
              },
              failure: nil,
              updated_at: now,
              version: current.version + 1
            )
            store.replace(:orders, completed, expected_version: current.version)
          end
        end

        def fail_execution(started, error)
          now = current_time

          @store.transaction do |store|
            current = store.fetch(:orders, started.id)
            ensure_same_attempt!(started, current)

            failed = rebuild_order(
              current,
              status: "failed",
              result: nil,
              failure: {
                code: error.code,
                retryable: error.retryable,
                details: error.details
              },
              updated_at: now,
              version: current.version + 1
            )
            store.replace(:orders, failed, expected_version: current.version)
          end
        rescue Conflict
          nil
        end

        def invoke_quote(provider, intent)
          result = provider.quote(intent: intent)
          return result if result.is_a?(Contracts::QuoteResult)

          raise ProviderContractError.new("provider quote returned an invalid result")
        rescue ProviderFailure
          raise
        rescue StandardError => error
          raise ProviderFailure.new(
            "provider quote raised an unexpected error",
            code: "unhandled_provider_error",
            retryable: false,
            details: { exception: error.class.name }
          )
        end

        def provider_for(capability)
          @providers.fetch(capability)
        rescue KeyError
          raise UnknownCapability.new(capability)
        end

        def provider_key(provider)
          RecordSupport.identifier(provider.key, field: "provider key")
        end

        def ensure_provider_identity!(provider, order)
          return if provider_key(provider) == order.provider_key

          raise ProviderFailure.new(
            "the order provider is unavailable",
            code: "provider_unavailable",
            retryable: true,
            details: { provider_key: order.provider_key }
          )
        end

        def ensure_same_attempt!(started, current)
          return if current.status == "processing" && current.attempts == started.attempts

          raise ConcurrencyConflict.new("order", current.id)
        end

        def ensure_status!(order, allowed:, event:)
          return if allowed.include?(order.status)

          raise InvalidTransition.new(
            resource: "order",
            id: order.id,
            from: order.status,
            event: event
          )
        end

        def rebuild_order(order, **changes)
          attributes = {
            id: order.id,
            intent_id: order.intent_id,
            quote_id: order.quote_id,
            capability: order.capability,
            provider_key: order.provider_key,
            payload: order.payload,
            context: order.context,
            terms: order.terms,
            private_state: order.private_state,
            status: order.status,
            attempts: order.attempts,
            result: order.result,
            failure: order.failure,
            created_at: order.created_at,
            updated_at: order.updated_at,
            version: order.version
          }
          Order.new(**attributes.merge(changes))
        end

        def order_id_for(quote)
          "order:#{quote.id}"
        end

        def current_time
          value = @clock.call
          raise ProviderContractError.new("clock must return a Time") unless value.is_a?(Time)

          value.getutc
        end

        def next_id
          RecordSupport.identifier(@id_generator.call, field: "generated id")
        end
      end
    end
  end
end

