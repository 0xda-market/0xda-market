# frozen_string_literal: true

require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Telegram
      class ClientBot
        START_TEXT = <<~TEXT.freeze
          zeroxda-market · client

          надішли, що хочеш отримати:
          • tg premium 12 months
          • 100 stars
          • 7.7 ton

          це demo: оплата буде mock, без реальних коштів.
        TEXT

        def initialize(flow:, api:)
          @flow = flow
          @api = api
        end

        def handle(update)
          if (callback = update["callback_query"])
            handle_callback(callback)
          elsif (message = update["message"])
            handle_message(message)
          end
        end

        private

        def handle_message(message)
          return unless private_chat?(message["chat"])

          chat_id = message.fetch("chat").fetch("id").to_s
          text = message["text"]
          if command(text) == "/start" || command(text) == "/help"
            @api.send_message(chat_id: chat_id, text: START_TEXT)
            return
          end
          if text.nil? || text.strip.empty?
            @api.send_message(chat_id: chat_id, text: "надішли запит звичайним текстом.")
            return
          end
          if command(text)
            @api.send_message(chat_id: chat_id, text: START_TEXT)
            return
          end

          @flow.submit_request(client: profile(message), item: text)
        rescue ArgumentError => error
          @api.send_message(chat_id: chat_id, text: "не вдалося створити запит: #{error.message}")
        end

        def handle_callback(callback)
          message = callback["message"]
          return unless message && private_chat?(message["chat"])

          callback_id = callback.fetch("id")
          chat_id = message.fetch("chat").fetch("id").to_s
          data = callback["data"].to_s
          if (match = data.match(/\Apay:(manual-[a-f0-9]{32})\z/))
            result = @flow.pay(task_id: match[1], client_chat_id: chat_id)
            text = result == :paid ? "demo-payment підтверджено" : "demo-payment уже підтверджено"
            @api.answer_callback_query(callback_query_id: callback_id, text: text)
          else
            @api.answer_callback_query(
              callback_query_id: callback_id,
              text: "ця дія більше недоступна",
              show_alert: true
            )
          end
        rescue Core::Conflict, Core::NotFound => error
          @api.answer_callback_query(
            callback_query_id: callback_id,
            text: callback_error(error),
            show_alert: true
          )
        end

        def profile(message)
          from = message.fetch("from")
          {
            chat_id: message.fetch("chat").fetch("id").to_s,
            user_id: from.fetch("id").to_s,
            username: from["username"]
          }
        end

        def command(text)
          return nil unless text.is_a?(String) && text.start_with?("/")

          text.split(/\s+/, 2).first.split("@", 2).first.downcase
        end

        def private_chat?(chat)
          chat.is_a?(Hash) && chat["type"] == "private"
        end

        def callback_error(error)
          case error.code
          when "broker_required" then "брокера ще не знайдено"
          when "telegram_actor_mismatch" then "цей запит належить іншому клієнту"
          else "ця дія більше недоступна"
          end
        end
      end
    end
  end
end
