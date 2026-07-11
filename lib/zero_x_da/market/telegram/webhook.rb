# frozen_string_literal: true

require "json"
require "rack"
require_relative "../core/records"
require_relative "records"

module ZeroXDA
  module Market
    module Telegram
      class Webhook
        MAX_BODY_BYTES = 1_048_576
        JSON_HEADERS = {
          "content-type" => "application/json; charset=utf-8",
          "cache-control" => "no-store"
        }.freeze

        def initialize(role:, secret_token:, handler:, store:, clock:, logger: nil)
          @role = role.to_s
          raise ArgumentError, "Telegram bot role is invalid" unless BOT_ROLES.include?(@role)

          @secret_token = secret_token.to_s
          raise ArgumentError, "Telegram webhook secret is required" if @secret_token.empty?

          @handler = handler
          @store = store
          @clock = clock
          @logger = logger || ->(message) { warn(message) }
        end

        def call(environment)
          request = Rack::Request.new(environment)
          return response(405, error: "method_not_allowed") unless request.post?
          return response(401, error: "unauthorized") unless authorized?(request)

          update = parse_update(request)
          update_id = update.fetch("update_id")
          unless update_id.is_a?(Integer) && update_id >= 0
            raise ArgumentError, "Telegram update id is invalid"
          end

          fresh = @store.claim_update(bot_role: @role, update_id: update_id, at: current_time)
          @handler.handle(update) if fresh
          response(200, ok: true)
        rescue JSON::ParserError, KeyError, ArgumentError => error
          response(400, error: "invalid_update", message: error.message)
        rescue StandardError => error
          @logger.call("[telegram.#{@role}] #{error.class}: #{error.message}")
          response(500, error: "internal_error")
        end

        private

        def authorized?(request)
          supplied = request.get_header("HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN").to_s
          return false unless supplied.bytesize == @secret_token.bytesize

          Rack::Utils.secure_compare(supplied, @secret_token)
        end

        def parse_update(request)
          raw = request.body.read(MAX_BODY_BYTES + 1)
          raise ArgumentError, "Telegram update is too large" if raw.bytesize > MAX_BODY_BYTES

          Core::RecordSupport.document(JSON.parse(raw), field: "Telegram update")
        end

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end

        def response(status, document)
          [status, JSON_HEADERS, [JSON.generate(document)]]
        end
      end
    end
  end
end
