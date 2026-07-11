# frozen_string_literal: true

require "monitor"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Adapters
      class MemoryStore
        COLLECTIONS = %i[intents quotes orders].freeze

        def initialize
          @records = COLLECTIONS.to_h { |collection| [collection, {}] }
          @monitor = Monitor.new
        end

        def transaction
          @monitor.synchronize do
            snapshot = @records.transform_values(&:dup)
            committed = false

            begin
              result = yield self
              committed = true
              result
            ensure
              @records = snapshot unless committed
            end
          end
        end

        def insert(collection, record)
          @monitor.synchronize do
            records = collection!(collection)
            if records.key?(record.id)
              raise Core::Conflict.new(
                "#{resource_name(collection)} already exists",
                code: "duplicate_record",
                details: { resource: resource_name(collection), id: record.id }
              )
            end

            records[record.id] = record
          end
          record
        end

        def find(collection, id)
          @monitor.synchronize { collection!(collection)[id.to_s] }
        end

        def fetch(collection, id)
          find(collection, id) || raise(Core::NotFound.new(resource_name(collection), id))
        end

        def replace(collection, record, expected_version:)
          @monitor.synchronize do
            records = collection!(collection)
            current = records[record.id]
            raise Core::NotFound.new(resource_name(collection), record.id) unless current

            if current.version != expected_version
              raise Core::ConcurrencyConflict.new(resource_name(collection), record.id)
            end

            records[record.id] = record
          end
          record
        end

        def healthy?
          true
        end

        private

        def collection!(name)
          @records.fetch(name.to_sym)
        rescue KeyError
          raise ArgumentError, "unknown collection: #{name}"
        end

        def resource_name(collection)
          collection.to_s.delete_suffix("s")
        end
      end
    end
  end
end
