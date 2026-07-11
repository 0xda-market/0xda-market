# frozen_string_literal: true

require "monitor"
require_relative "records"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Telegram
      class MemoryStore
        def initialize
          @brokers = {}
          @orders = {}
          @updates = {}
          @monitor = Monitor.new
        end

        def register_broker(chat_id:, user_id:, username:, display_name:, at:)
          @monitor.synchronize do
            existing = @brokers[chat_id.to_s]
            broker = Broker.new(
              chat_id: chat_id,
              user_id: user_id,
              username: username,
              display_name: display_name,
              status: "ready",
              created_at: existing&.created_at || at,
              updated_at: at
            )
            @brokers[broker.chat_id] = broker
          end
        end

        def set_broker_status(chat_id:, status:, at:)
          @monitor.synchronize do
            current = @brokers.fetch(chat_id.to_s) do
              raise Core::NotFound.new("telegram_broker", chat_id)
            end
            replacement = Broker.new(
              chat_id: current.chat_id,
              user_id: current.user_id,
              username: current.username,
              display_name: current.display_name,
              status: status,
              created_at: current.created_at,
              updated_at: at
            )
            @brokers[replacement.chat_id] = replacement
          end
        end

        def ready_brokers
          @monitor.synchronize do
            @brokers.values
              .select { |broker| broker.status == "ready" }
              .sort_by { |broker| [broker.updated_at, broker.chat_id] }
          end
        end

        def fetch_broker(chat_id)
          @monitor.synchronize do
            @brokers.fetch(chat_id.to_s) do
              raise Core::NotFound.new("telegram_broker", chat_id)
            end
          end
        end

        def insert_demo_order(task_id:, order_id:, client_chat_id:, at:)
          @monitor.synchronize do
            if (existing = @orders[task_id.to_s])
              return existing if existing.order_id == order_id.to_s &&
                                 existing.client_chat_id == client_chat_id.to_s

              raise duplicate_order(task_id)
            end

            order = DemoOrder.new(
              task_id: task_id,
              order_id: order_id,
              client_chat_id: client_chat_id,
              created_at: at
            )
            @orders[order.task_id] = order
          end
        end

        def fetch_demo_order(task_id)
          @monitor.synchronize do
            @orders.fetch(task_id.to_s) do
              raise Core::NotFound.new("telegram_demo_order", task_id)
            end
          end
        end

        def pending_demo_orders
          @monitor.synchronize do
            @orders.values
              .select { |order| order.status == "broadcast" }
              .sort_by { |order| [order.created_at, order.task_id] }
          end
        end

        def assign_demo_order(task_id:, broker_chat_id:, at:)
          transition(task_id) do |order|
            if order.broker_chat_id == broker_chat_id.to_s
              next [order, false]
            end
            if order.broker_chat_id
              raise conflict("task_already_claimed", "demo order is already assigned", order)
            end

            [rebuild(order, broker_chat_id: broker_chat_id.to_s, status: "awaiting_payment", at: at), true]
          end
        end

        def pay_demo_order(task_id:, client_chat_id:, at:)
          transition(task_id) do |order|
            unless order.client_chat_id == client_chat_id.to_s
              raise conflict("telegram_actor_mismatch", "demo order belongs to another client", order)
            end
            next [order, false] if %w[processing completed].include?(order.status)
            unless order.status == "awaiting_payment"
              raise conflict("broker_required", "a broker must accept the order first", order)
            end

            [rebuild(order, status: "processing", at: at), true]
          end
        end

        def complete_demo_order(task_id:, broker_chat_id:, at:)
          transition(task_id) do |order|
            unless order.broker_chat_id == broker_chat_id.to_s
              raise conflict("telegram_actor_mismatch", "demo order belongs to another broker", order)
            end
            next [order, false] if order.status == "completed"
            unless order.status == "processing"
              raise conflict("payment_required", "demo payment has not been confirmed", order)
            end

            [rebuild(order, status: "completed", at: at), true]
          end
        end

        def claim_update(bot_role:, update_id:, at:)
          validate_update!(bot_role, update_id, at)
          @monitor.synchronize do
            key = [bot_role.to_s, update_id]
            return false if @updates.key?(key)

            @updates[key] = at
            true
          end
        end

        private

        def transition(task_id)
          @monitor.synchronize do
            order = @orders.fetch(task_id.to_s) do
              raise Core::NotFound.new("telegram_demo_order", task_id)
            end
            replacement, changed = yield order
            @orders[order.task_id] = replacement if changed
            [replacement, changed]
          end
        end

        def rebuild(order, at:, **changes)
          DemoOrder.new(
            task_id: order.task_id,
            order_id: order.order_id,
            client_chat_id: order.client_chat_id,
            broker_chat_id: changes.fetch(:broker_chat_id, order.broker_chat_id),
            status: changes.fetch(:status, order.status),
            created_at: order.created_at,
            updated_at: at,
            version: order.version + 1
          )
        end

        def conflict(code, message, order)
          Core::Conflict.new(
            message,
            code: code,
            details: { resource: "telegram_demo_order", id: order.task_id }
          )
        end

        def duplicate_order(task_id)
          Core::Conflict.new(
            "Telegram demo order already exists",
            code: "duplicate_record",
            details: { resource: "telegram_demo_order", id: task_id.to_s }
          )
        end

        def validate_update!(bot_role, update_id, at)
          unless BOT_ROLES.include?(bot_role.to_s)
            raise ArgumentError, "Telegram bot role is invalid"
          end
          unless update_id.is_a?(Integer) && update_id >= 0
            raise ArgumentError, "Telegram update id must be a non-negative integer"
          end

          Core::RecordSupport.time(at, field: "received_at")
        end
      end
    end
  end
end
