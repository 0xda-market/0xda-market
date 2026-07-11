# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "../providers/manual_provider"

module ZeroXDA
  module Market
    module Adapters
      class PostgresManualTaskStore
        def initialize(database:)
          @connection = database.connection
          @tasks = @connection[Sequel.qualify(:market, :manual_tasks)]
        end

        def transaction
          @connection.transaction(savepoint: true) { yield self }
        end

        def insert(task)
          @tasks.insert(serialize(task))
          task
        rescue Sequel::UniqueConstraintViolation
          raise duplicate(task.id)
        end

        def find(id)
          row = @tasks.where(id: id.to_s).first
          row && deserialize(row)
        end

        def fetch(id)
          find(id) || raise(Core::NotFound.new("manual_task", id))
        end

        def list(status: nil)
          dataset = status ? @tasks.where(status: status) : @tasks
          dataset.order(:created_at, :id).all.map { |row| deserialize(row) }
        end

        def replace(task, expected_version:)
          count = @tasks.where(id: task.id, version: expected_version).update(serialize(task))
          return task if count == 1

          raise Core::NotFound.new("manual_task", task.id) unless @tasks.where(id: task.id).get(:id)
          raise Core::ConcurrencyConflict.new("manual_task", task.id)
        end

        private

        def serialize(task)
          {
            id: task.id,
            order_id: task.order_id,
            capability: task.capability,
            payload: Sequel.pg_jsonb(task.payload),
            context: Sequel.pg_jsonb(task.context),
            terms: Sequel.pg_jsonb(task.terms),
            status: task.status,
            result: task.result && Sequel.pg_jsonb(task.result),
            failure: task.failure && Sequel.pg_jsonb(task.failure),
            created_at: task.created_at,
            updated_at: task.updated_at,
            version: task.version
          }
        end

        def deserialize(row)
          Providers::ManualProvider::Task.new(
            id: row.fetch(:id),
            order_id: row.fetch(:order_id),
            capability: row.fetch(:capability),
            payload: document(row.fetch(:payload)),
            context: document(row.fetch(:context)),
            terms: document(row.fetch(:terms)),
            status: row.fetch(:status),
            result: optional_document(row[:result]),
            failure: optional_document(row[:failure]),
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            version: row.fetch(:version)
          )
        end

        def document(value)
          value.respond_to?(:to_hash) ? value.to_hash : value
        end

        def optional_document(value)
          value && document(value)
        end

        def duplicate(id)
          Core::Conflict.new(
            "manual task already exists",
            code: "duplicate_record",
            details: { resource: "manual_task", id: id }
          )
        end
      end
    end
  end
end
