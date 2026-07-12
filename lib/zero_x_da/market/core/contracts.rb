# frozen_string_literal: true

require_relative "records"

module ZeroXDA
  module Market
    module Core
      class Error < StandardError
        attr_reader :code, :details

        def initialize(message, code:, details: {})
          @code = code.to_s.dup.freeze
          @details = RecordSupport.document(details, field: "error details")
          super(message)
        end
      end

      class NotFound < Error
        def initialize(resource, id)
          super(
            "#{resource} was not found",
            code: "not_found",
            details: { resource: resource.to_s, id: id.to_s }
          )
        end
      end

      class Conflict < Error
        def initialize(message, code: "conflict", details: {})
          super(message, code: code, details: details)
        end
      end

      class Forbidden < Error
        def initialize(message = "access is forbidden", details: {})
          super(message, code: "forbidden", details: details)
        end
      end

      class ConcurrencyConflict < Conflict
        def initialize(resource, id)
          super(
            "#{resource} changed concurrently",
            code: "concurrency_conflict",
            details: { resource: resource.to_s, id: id.to_s }
          )
        end
      end

      class InvalidTransition < Conflict
        def initialize(resource:, id:, from:, event:)
          super(
            "#{resource} cannot handle #{event} while #{from}",
            code: "invalid_transition",
            details: {
              resource: resource.to_s,
              id: id.to_s,
              from: from.to_s,
              event: event.to_s
            }
          )
        end
      end

      class QuoteExpired < Conflict
        def initialize(id)
          super(
            "quote has expired",
            code: "quote_expired",
            details: { id: id.to_s }
          )
        end
      end

      class UnknownCapability < Error
        def initialize(capability)
          super(
            "no provider is registered for this capability",
            code: "unknown_capability",
            details: { capability: capability.to_s }
          )
        end
      end

      class ProviderFailure < Error
        attr_reader :retryable

        def initialize(message, code: "provider_failure", retryable: false, details: {})
          @retryable = !!retryable
          super(message, code: code, details: details)
        end
      end

      class ProviderContractError < ProviderFailure
        def initialize(message, details: {})
          super(
            message,
            code: "provider_contract_error",
            retryable: false,
            details: details
          )
        end
      end

      module Contracts
        class QuoteResult
          attr_reader :terms, :private_state, :expires_at

          def initialize(terms:, private_state: {}, expires_at: nil)
            @terms = RecordSupport.document(terms, field: "terms")
            @private_state = RecordSupport.document(private_state, field: "private_state")
            @expires_at = RecordSupport.optional_time(expires_at, field: "expires_at")
            freeze
          end
        end

        class ExecutionResult
          attr_reader :reference, :data

          def initialize(reference: nil, data: {})
            unless reference.nil? || reference.is_a?(String)
              raise ArgumentError, "reference must be a string or nil"
            end

            @reference = reference&.dup&.freeze
            @data = RecordSupport.document(data, field: "data")
            freeze
          end
        end

        class PendingResult
          attr_reader :reference, :data

          def initialize(reference:, data: {})
            @reference = RecordSupport.identifier(reference, field: "pending reference")
            @data = RecordSupport.document(data, field: "data")
            freeze
          end
        end

        module_function

        def validate_provider!(provider)
          required = %i[key quote execute]
          missing = required.reject { |method_name| provider.respond_to?(method_name) }
          return provider if missing.empty?

          raise ProviderContractError.new(
            "provider does not implement the required contract",
            details: { missing_methods: missing.map(&:to_s) }
          )
        end
      end
    end
  end
end
