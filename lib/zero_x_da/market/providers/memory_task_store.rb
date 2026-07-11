# frozen_string_literal: true

require "monitor"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Providers
      class MemoryTaskStore
        def initialize
          @tasks = {}
          @monitor = Monitor.new
        end

        def transaction
          @monitor.synchronize do
            snapshot = @tasks.dup
            committed = false
            begin
              result = yield self
              committed = true
              result
            ensure
              @tasks = snapshot unless committed
            end
          end
        end

        def insert(task)
          @monitor.synchronize do
            raise duplicate(task.id) if @tasks.key?(task.id)

            @tasks[task.id] = task
          end
          task
        end

        def find(id)
          @monitor.synchronize { @tasks[id.to_s] }
        end

        def fetch(id)
          find(id) || raise(Core::NotFound.new("manual_task", id))
        end

        def list(status: nil)
          @monitor.synchronize do
            tasks = @tasks.values
            tasks = tasks.select { |task| task.status == status } if status
            tasks.sort_by(&:created_at)
          end
        end

        def replace(task, expected_version:)
          @monitor.synchronize do
            current = @tasks[task.id]
            raise Core::NotFound.new("manual_task", task.id) unless current
            if current.version != expected_version
              raise Core::ConcurrencyConflict.new("manual_task", task.id)
            end

            @tasks[task.id] = task
          end
          task
        end

        private

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
