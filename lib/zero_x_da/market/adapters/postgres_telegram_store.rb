# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "../telegram/records"

module ZeroXDA
  module Market
    module Adapters
      class PostgresTelegramStore
        def initialize(database:)
          @connection = database.connection
          @brokers = @connection[Sequel.qualify(:market, :telegram_brokers)]
          @orders = @connection[Sequel.qualify(:market, :telegram_demo_orders)]
          @updates = @connection[Sequel.qualify(:market, :telegram_updates)]
        end

        def register_broker(chat_id:, user_id:, username:, display_name:, at:)
          existing_created_at = @brokers.where(chat_id: chat_id.to_s).get(:created_at)
          broker = Telegram::Broker.new(
            chat_id: chat_id,
            user_id: user_id,
            username: username,
            display_name: display_name,
            status: "ready",
            created_at: existing_created_at || at,
            updated_at: at
          )
          values = serialize_broker(broker)
          @brokers.insert_conflict(
            target: :chat_id,
            update: values.reject { |key, _value| key == :created_at || key == :chat_id }
          ).insert(values)
          deserialize_broker(@brokers.where(chat_id: chat_id.to_s).first)
        end

        def set_broker_status(chat_id:, status:, at:)
          current = fetch_broker(chat_id)
          replacement = Telegram::Broker.new(
            chat_id: current.chat_id,
            user_id: current.user_id,
            username: current.username,
            display_name: current.display_name,
            status: status,
            created_at: current.created_at,
            updated_at: at
          )
          updated = @brokers.where(chat_id: current.chat_id)
            .update(serialize_broker(replacement))
          raise Core::NotFound.new("telegram_broker", chat_id) unless updated == 1

          replacement
        end

        def ready_brokers
          @brokers.where(status: "ready")
            .order(:updated_at, :chat_id)
            .all
            .map { |row| deserialize_broker(row) }
        end

        def fetch_broker(chat_id)
          row = @brokers.where(chat_id: chat_id.to_s).first
          row ? deserialize_broker(row) : raise(Core::NotFound.new("telegram_broker", chat_id))
        end

        def insert_demo_order(task_id:, order_id:, client_chat_id:, at:)
          order = Telegram::DemoOrder.new(
            task_id: task_id,
            order_id: order_id,
            client_chat_id: client_chat_id,
            created_at: at
          )
          @orders.insert(serialize_order(order))
          order
        rescue Sequel::UniqueConstraintViolation
          existing = @orders.where(task_id: task_id.to_s).first
          if existing
            persisted = deserialize_order(existing)
            return persisted if persisted.order_id == order_id.to_s &&
                                persisted.client_chat_id == client_chat_id.to_s
          end

          raise duplicate_order(task_id)
        end

        def fetch_demo_order(task_id)
          row = @orders.where(task_id: task_id.to_s).first
          row ? deserialize_order(row) : raise(Core::NotFound.new("telegram_demo_order", task_id))
        end

        def pending_demo_orders
          @orders.where(status: "broadcast")
            .order(:created_at, :task_id)
            .all
            .map { |row| deserialize_order(row) }
        end

        def assign_demo_order(task_id:, broker_chat_id:, at:)
          transition(task_id) do |order|
            next [order, false] if order.broker_chat_id == broker_chat_id.to_s
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
          @updates.insert(bot_role: bot_role.to_s, update_id: update_id, received_at: at)
          true
        rescue Sequel::UniqueConstraintViolation
          false
        end

        private

        def transition(task_id)
          @connection.transaction(savepoint: true) do
            row = @orders.where(task_id: task_id.to_s).for_update.first
            raise Core::NotFound.new("telegram_demo_order", task_id) unless row

            order = deserialize_order(row)
            replacement, changed = yield order
            if changed
              updated = @orders.where(task_id: order.task_id, version: order.version)
                .update(serialize_order(replacement))
              unless updated == 1
                raise Core::ConcurrencyConflict.new("telegram_demo_order", order.task_id)
              end
            end
            [replacement, changed]
          end
        end

        def rebuild(order, at:, **changes)
          Telegram::DemoOrder.new(
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

        def serialize_order(order)
          {
            task_id: order.task_id,
            order_id: order.order_id,
            client_chat_id: order.client_chat_id,
            broker_chat_id: order.broker_chat_id,
            status: order.status,
            created_at: order.created_at,
            updated_at: order.updated_at,
            version: order.version
          }
        end

        def serialize_broker(broker)
          {
            chat_id: broker.chat_id,
            user_id: broker.user_id,
            username: broker.username,
            display_name: broker.display_name,
            status: broker.status,
            created_at: broker.created_at,
            updated_at: broker.updated_at
          }
        end

        def deserialize_order(row)
          Telegram::DemoOrder.new(**row)
        end

        def deserialize_broker(row)
          Telegram::Broker.new(**row)
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
          unless Telegram::BOT_ROLES.include?(bot_role.to_s)
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
