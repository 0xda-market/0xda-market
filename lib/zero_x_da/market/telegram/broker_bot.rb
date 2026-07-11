# frozen_string_literal: true

require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Telegram
      class BrokerBot
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
          case command(message["text"])
          when "/start", "/ready"
            @flow.ready_broker(profile(message))
          when "/offline"
            begin
              @flow.offline_broker(chat_id)
            rescue Core::NotFound
              @api.send_message(chat_id: chat_id, text: "спочатку авторизуйся командою /start.")
            end
          else
            @api.send_message(
              chat_id: chat_id,
              text: "команди: /ready — приймати пропозиції; /offline — призупинити."
            )
          end
        end

        def handle_callback(callback)
          message = callback["message"]
          return unless message && private_chat?(message["chat"])

          callback_id = callback.fetch("id")
          chat_id = message.fetch("chat").fetch("id").to_s
          data = callback["data"].to_s

          case data
          when "status:ready"
            @flow.ready_broker(profile_from_callback(callback))
            answer(callback_id, "статус: ready")
          when "status:offline"
            @flow.offline_broker(chat_id)
            answer(callback_id, "статус: offline")
          when /\Aaccept:(manual-[a-f0-9]{32})\z/
            result = @flow.accept(task_id: Regexp.last_match(1), broker_chat_id: chat_id)
            if result == :unavailable
              answer(callback_id, "пропозицію вже прийняв інший брокер", alert: true)
            else
              answer(callback_id, "пропозицію прийнято")
            end
          when /\Acomplete:(manual-[a-f0-9]{32})\z/
            result = @flow.complete(task_id: Regexp.last_match(1), broker_chat_id: chat_id)
            text = result == :completed ? "виконання зафіксовано" : "вже виконано"
            answer(callback_id, text)
          else
            answer(callback_id, "ця дія більше недоступна", alert: true)
          end
        rescue Core::Conflict, Core::NotFound => error
          answer(callback_id, callback_error(error), alert: true)
        end

        def profile(message)
          profile_from(message.fetch("from"), message.fetch("chat").fetch("id"))
        end

        def profile_from_callback(callback)
          message = callback.fetch("message")
          profile_from(callback.fetch("from"), message.fetch("chat").fetch("id"))
        end

        def profile_from(from, chat_id)
          display_name = [from["first_name"], from["last_name"]].compact.join(" ").strip
          display_name = from["username"].to_s if display_name.empty?
          display_name = "broker" if display_name.empty?
          {
            chat_id: chat_id.to_s,
            user_id: from.fetch("id").to_s,
            username: from["username"],
            display_name: display_name
          }
        end

        def command(text)
          return nil unless text.is_a?(String) && text.start_with?("/")

          text.split(/\s+/, 2).first.split("@", 2).first.downcase
        end

        def private_chat?(chat)
          chat.is_a?(Hash) && chat["type"] == "private"
        end

        def answer(callback_id, text, alert: false)
          @api.answer_callback_query(
            callback_query_id: callback_id,
            text: text,
            show_alert: alert
          )
        end

        def callback_error(error)
          case error.code
          when "broker_not_ready" then "спочатку увімкни ready"
          when "payment_required" then "demo-payment ще не підтверджено"
          when "telegram_actor_mismatch" then "цю пропозицію прийняв інший брокер"
          else "ця дія більше недоступна"
          end
        end
      end
    end
  end
end
