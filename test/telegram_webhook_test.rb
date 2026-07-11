# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "zero_x_da/market/telegram/memory_store"
require "zero_x_da/market/telegram/webhook"

class TelegramWebhookTest < Minitest::Test
  class Handler
    attr_reader :updates

    def initialize
      @updates = []
    end

    def handle(update)
      @updates << update
    end
  end

  def setup
    @handler = Handler.new
    @app = ZeroXDA::Market::Telegram::Webhook.new(
      role: "client",
      secret_token: "webhook-secret",
      handler: @handler,
      store: ZeroXDA::Market::Telegram::MemoryStore.new,
      clock: MutableClock.new,
      logger: ->(_message) {}
    )
    @client = Rack::MockRequest.new(@app)
  end

  def test_authenticates_and_deduplicates_updates
    first = post(update_id: 77, message: { text: "/start" })
    duplicate = post(update_id: 77, message: { text: "/start" })

    assert_equal 200, first.status
    assert_equal 200, duplicate.status
    assert_equal 1, @handler.updates.length
  end

  def test_rejects_an_invalid_secret
    response = @client.post(
      "/",
      "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "wrong",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(update_id: 1)
    )

    assert_equal 401, response.status
    assert_empty @handler.updates
  end

  def test_rejects_invalid_json
    response = @client.post(
      "/",
      "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "webhook-secret",
      "CONTENT_TYPE" => "application/json",
      input: "{"
    )

    assert_equal 400, response.status
  end

  private

  def post(document)
    @client.post(
      "/",
      "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN" => "webhook-secret",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(document)
    )
  end
end
