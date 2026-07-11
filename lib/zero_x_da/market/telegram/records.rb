# frozen_string_literal: true

require_relative "../core/records"

module ZeroXDA
  module Market
    module Telegram
      BOT_ROLES = %w[client broker].freeze

      class Broker
        STATUSES = %w[ready offline].freeze

        attr_reader :chat_id,
                    :user_id,
                    :username,
                    :display_name,
                    :status,
                    :created_at,
                    :updated_at

        def initialize(
          chat_id:,
          user_id:,
          username: nil,
          display_name:,
          status:,
          created_at:,
          updated_at: created_at
        )
          raise ArgumentError, "broker status is invalid" unless STATUSES.include?(status)

          @chat_id = identifier(chat_id, "broker chat id")
          @user_id = identifier(user_id, "broker user id")
          @username = username && identifier(username, "broker username")
          @display_name = identifier(display_name, "broker display name")
          @status = status.dup.freeze
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          freeze
        end

        private

        def identifier(value, field)
          Core::RecordSupport.identifier(value.to_s, field: field)
        end
      end

      class DemoOrder
        STATUSES = %w[broadcast awaiting_payment processing completed].freeze

        attr_reader :task_id,
                    :order_id,
                    :client_chat_id,
                    :broker_chat_id,
                    :status,
                    :created_at,
                    :updated_at,
                    :version

        def initialize(
          task_id:,
          order_id:,
          client_chat_id:,
          broker_chat_id: nil,
          status: "broadcast",
          created_at:,
          updated_at: created_at,
          version: 0
        )
          raise ArgumentError, "Telegram demo order status is invalid" unless STATUSES.include?(status)

          @task_id = identifier(task_id, "manual task id")
          @order_id = identifier(order_id, "order id")
          @client_chat_id = identifier(client_chat_id, "client chat id")
          @broker_chat_id = broker_chat_id && identifier(broker_chat_id, "broker chat id")
          if status != "broadcast" && @broker_chat_id.nil?
            raise ArgumentError, "assigned Telegram demo order must have a broker"
          end
          @status = status.dup.freeze
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end

        private

        def identifier(value, field)
          Core::RecordSupport.identifier(value.to_s, field: field)
        end
      end
    end
  end
end
