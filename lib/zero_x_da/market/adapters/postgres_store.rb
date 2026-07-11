# frozen_string_literal: true

require_relative "postgres_database"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Adapters
      class PostgresStore
        COLLECTIONS = %i[intents quotes orders].freeze

        def initialize(database:)
          @database = database
          @connection = database.connection
        end

        def transaction
          @connection.transaction(savepoint: true) { yield self }
        end

        def insert(collection, record)
          dataset(collection).insert(serialize(collection, record))
          record
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new(
            "#{resource_name(collection)} already exists",
            code: "duplicate_record",
            details: { resource: resource_name(collection), id: record.id }
          )
        end

        def find(collection, id)
          row = dataset(collection).where(id: id.to_s).first
          row && deserialize(collection, row)
        end

        def fetch(collection, id)
          find(collection, id) || raise(Core::NotFound.new(resource_name(collection), id))
        end

        def replace(collection, record, expected_version:)
          updated = dataset(collection)
            .where(id: record.id, version: expected_version)
            .update(serialize(collection, record))
          return record if updated == 1

          if dataset(collection).where(id: record.id).empty?
            raise Core::NotFound.new(resource_name(collection), record.id)
          end

          raise Core::ConcurrencyConflict.new(resource_name(collection), record.id)
        end

        def healthy?
          @database.healthy?
        end

        private

        def dataset(collection)
          normalized = collection.to_sym
          raise ArgumentError, "unknown collection: #{collection}" unless COLLECTIONS.include?(normalized)

          @connection[Sequel.qualify(:market, normalized)]
        end

        def serialize(collection, record)
          case collection.to_sym
          when :intents
            {
              id: record.id,
              capability: record.capability,
              payload: json(record.payload),
              context: json(record.context),
              created_at: record.created_at,
              version: record.version
            }
          when :quotes
            {
              id: record.id,
              intent_id: record.intent_id,
              provider_key: record.provider_key,
              terms: json(record.terms),
              private_state: json(record.private_state),
              expires_at: record.expires_at,
              created_at: record.created_at,
              version: record.version
            }
          when :orders
            {
              id: record.id,
              intent_id: record.intent_id,
              quote_id: record.quote_id,
              capability: record.capability,
              provider_key: record.provider_key,
              payload: json(record.payload),
              context: json(record.context),
              terms: json(record.terms),
              private_state: json(record.private_state),
              status: record.status,
              attempts: record.attempts,
              progress: optional_json(record.progress),
              result: optional_json(record.result),
              failure: optional_json(record.failure),
              created_at: record.created_at,
              updated_at: record.updated_at,
              version: record.version
            }
          end
        end

        def deserialize(collection, row)
          attributes = row.transform_values { |value| plain_json(value) }
          case collection.to_sym
          when :intents then Core::Intent.new(**attributes)
          when :quotes then Core::Quote.new(**attributes)
          when :orders then Core::Order.new(**attributes)
          end
        end

        def json(value)
          Sequel.pg_jsonb(value)
        end

        def optional_json(value)
          value && json(value)
        end

        def plain_json(value)
          value.respond_to?(:to_hash) ? value.to_hash : value
        end

        def resource_name(collection)
          collection.to_s.delete_suffix("s")
        end
      end
    end
  end
end
