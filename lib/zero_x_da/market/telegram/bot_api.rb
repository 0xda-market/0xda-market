# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "uri"

module ZeroXDA
  module Market
    module Telegram
      class BotAPI
        class Error < StandardError; end

        def initialize(token:, transport: nil)
          unless token.is_a?(String) && !token.empty?
            raise ArgumentError, "Telegram bot token must be a non-empty string"
          end

          @token = token.dup.freeze
          @transport = transport
        end

        def send_message(chat_id:, text:, reply_markup: nil)
          payload = {
            chat_id: chat_id.to_s,
            text: text.to_s,
            link_preview_options: { is_disabled: true }
          }
          payload[:reply_markup] = reply_markup if reply_markup
          request("sendMessage", payload)
        end

        def answer_callback_query(callback_query_id:, text: nil, show_alert: false)
          payload = {
            callback_query_id: callback_query_id.to_s,
            show_alert: show_alert
          }
          payload[:text] = text.to_s if text
          request("answerCallbackQuery", payload)
        end

        def set_webhook(url:, secret_token:)
          request(
            "setWebhook",
            {
              url: url,
              secret_token: secret_token,
              allowed_updates: %w[message callback_query],
              drop_pending_updates: false
            }
          )
        end

        private

        def request(method, payload)
          return @transport.call(method, payload) if @transport

          uri = URI("https://api.telegram.org/bot#{@token}/#{method}")
          request = Net::HTTP::Post.new(uri)
          request["content-type"] = "application/json"
          request.body = JSON.generate(payload)
          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: 5,
            read_timeout: 10
          ) { |http| http.request(request) }
          document = JSON.parse(response.body)
          return document["result"] if response.is_a?(Net::HTTPSuccess) && document["ok"]

          description = document["description"] || "request was rejected"
          raise Error, "Telegram API #{method} failed: #{description}"
        rescue Error
          raise
        rescue StandardError
          raise Error, "Telegram API #{method} failed"
        end
      end
    end
  end
end
