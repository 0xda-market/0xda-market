# frozen_string_literal: true

require "digest"
require_relative "../core/contracts"
require_relative "memory_task_store"

module ZeroXDA
  module Market
    module Providers
      class ManualProvider
        class Task
          STATUSES = %w[pending claimed completed rejected].freeze

          attr_reader :id,
                      :order_id,
                      :capability,
                      :payload,
                      :context,
                      :terms,
                      :status,
                      :claimed_by,
                      :result,
                      :failure,
                      :created_at,
                      :updated_at,
                      :version

          def initialize(
            id:,
            order_id:,
            capability:,
            payload:,
            context:,
            terms:,
            status: "pending",
            claimed_by: nil,
            result: nil,
            failure: nil,
            created_at:,
            updated_at: created_at,
            version: 0
          )
            raise ArgumentError, "task status is invalid" unless STATUSES.include?(status)

            @id = Core::RecordSupport.identifier(id, field: "task id")
            @order_id = Core::RecordSupport.identifier(order_id, field: "order id")
            @capability = Core::RecordSupport.capability(capability)
            @payload = Core::RecordSupport.document(payload, field: "payload")
            @context = Core::RecordSupport.document(context, field: "context")
            @terms = Core::RecordSupport.document(terms, field: "terms")
            @status = status.dup.freeze
            @claimed_by = claimed_by && Core::RecordSupport.identifier(
              claimed_by,
              field: "task assignee"
            )
            if status == "claimed" && @claimed_by.nil?
              raise ArgumentError, "claimed task must have an assignee"
            end
            @result = Core::RecordSupport.optional_document(result, field: "result")
            @failure = Core::RecordSupport.optional_document(failure, field: "failure")
            @created_at = Core::RecordSupport.time(created_at, field: "created_at")
            @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
            unless version.is_a?(Integer) && version >= 0
              raise ArgumentError, "task version must be a non-negative integer"
            end
            @version = version
            freeze
          end
        end

        attr_reader :key

        def initialize(
          key:,
          clock:,
          quote_terms: { fulfillment: "manual" },
          quote_ttl: nil,
          task_store: MemoryTaskStore.new
        )
          @key = Core::RecordSupport.identifier(key, field: "provider key")
          @clock = clock
          @quote_terms = Core::RecordSupport.document(quote_terms, field: "quote terms")
          unless quote_ttl.nil? || (quote_ttl.is_a?(Numeric) && quote_ttl.positive?)
            raise ArgumentError, "quote_ttl must be a positive number or nil"
          end

          @quote_ttl = quote_ttl
          @task_store = task_store
        end

        def quote(intent:)
          now = current_time
          Core::Contracts::QuoteResult.new(
            terms: @quote_terms,
            private_state: { manual_intent_id: intent.id },
            expires_at: @quote_ttl && now + @quote_ttl
          )
        end

        def execute(order:, idempotency_key:)
          task = find_or_create_task(order, idempotency_key)

          case task.status
          when "pending", "claimed"
            Core::Contracts::PendingResult.new(
              reference: task.id,
              data: { status: task.status == "claimed" ? "operator_claimed" : "awaiting_operator" }
            )
          when "completed"
            Core::Contracts::ExecutionResult.new(
              reference: task.result.fetch("reference"),
              data: task.result.fetch("data")
            )
          when "rejected"
            raise Core::ProviderFailure.new(
              task.failure.fetch("message"),
              code: task.failure.fetch("code"),
              retryable: task.failure.fetch("retryable"),
              details: task.failure.fetch("details")
            )
          end
        end

        def tasks(status: nil)
          validate_status_filter!(status)
          @task_store.list(status: status)
        end

        def find_task(id)
          @task_store.find(id)
        end

        def fetch_task(id)
          find_task(id) || raise(Core::NotFound.new("manual_task", id))
        end

        def claim_task(id, assignee:)
          normalized_assignee = Core::RecordSupport.identifier(
            assignee,
            field: "task assignee"
          )

          @task_store.transaction do |store|
            task = store.fetch(id)
            return task if task.status == "claimed" && task.claimed_by == normalized_assignee

            if task.status == "claimed"
              raise already_claimed(task)
            end

            ensure_status!(task, allowed: ["pending"], event: "claim")
            replace_task(
              store,
              task,
              status: "claimed",
              claimed_by: normalized_assignee,
              updated_at: current_time
            )
          end
        rescue Core::ConcurrencyConflict
          current = fetch_task(id)
          return current if current.status == "claimed" &&
                            current.claimed_by == normalized_assignee

          raise already_claimed(current) if current.status == "claimed"

          raise
        end

        def complete_task(id, reference: nil, data: {})
          @task_store.transaction do |store|
            task = store.fetch(id)
            return task if task.status == "completed"

            ensure_status!(task, allowed: %w[pending claimed], event: "complete")
            replace_task(
              store,
              task,
              status: "completed",
              result: { reference: reference, data: data },
              failure: nil,
              updated_at: current_time
            )
          end
        end

        def reject_task(id, message:, code: "manual_rejection", details: {})
          @task_store.transaction do |store|
            task = store.fetch(id)
            return task if task.status == "rejected"

            ensure_status!(task, allowed: %w[pending claimed], event: "reject")
            replace_task(
              store,
              task,
              status: "rejected",
              result: nil,
              failure: {
                message: Core::RecordSupport.identifier(message, field: "failure message"),
                code: Core::RecordSupport.identifier(code, field: "failure code"),
                retryable: false,
                details: details
              },
              updated_at: current_time
            )
          end
        end

        private

        def find_or_create_task(order, idempotency_key)
          normalized_key = Core::RecordSupport.identifier(
            idempotency_key,
            field: "idempotency key"
          )
          id = task_id_for(normalized_key)
          existing = @task_store.find(id)
          return existing if existing

          task = Task.new(
            id: id,
            order_id: order.id,
            capability: order.capability,
            payload: order.payload,
            context: order.context,
            terms: order.terms,
            created_at: current_time
          )
          @task_store.insert(task)
        rescue Core::Conflict => error
          raise unless error.code == "duplicate_record"

          @task_store.fetch(id)
        end

        def task_id_for(idempotency_key)
          "manual-#{Digest::SHA256.hexdigest(idempotency_key)[0, 32]}"
        end

        def replace_task(store, task, **changes)
          attributes = {
            id: task.id,
            order_id: task.order_id,
            capability: task.capability,
            payload: task.payload,
            context: task.context,
            terms: task.terms,
            status: task.status,
            claimed_by: task.claimed_by,
            result: task.result,
            failure: task.failure,
            created_at: task.created_at,
            updated_at: task.updated_at,
            version: task.version
          }
          replacement = Task.new(**attributes.merge(changes, version: task.version + 1))
          store.replace(replacement, expected_version: task.version)
        end

        def ensure_status!(task, allowed:, event:)
          return if allowed.include?(task.status)

          raise Core::InvalidTransition.new(
            resource: "manual_task",
            id: task.id,
            from: task.status,
            event: event
          )
        end

        def already_claimed(task)
          Core::Conflict.new(
            "manual task is already claimed",
            code: "task_already_claimed",
            details: { resource: "manual_task", id: task.id }
          )
        end

        def validate_status_filter!(status)
          return if status.nil? || Task::STATUSES.include?(status)

          raise ArgumentError, "task status filter is invalid"
        end

        def current_time
          value = @clock.call
          unless value.is_a?(Time)
            raise Core::ProviderContractError.new("clock must return a Time")
          end

          value.getutc
        end
      end
    end
  end
end
