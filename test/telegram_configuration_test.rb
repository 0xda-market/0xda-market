# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/telegram/bot_api"
require "zero_x_da/market/telegram/configuration"

class TelegramConfigurationTest < Minitest::Test
  def test_returns_nil_when_the_bots_are_not_configured
    assert_nil ZeroXDA::Market::Telegram::Configuration.from_env({})
  end

  def test_rejects_partial_configuration
    error = assert_raises(ArgumentError) do
      ZeroXDA::Market::Telegram::Configuration.from_env(
        "TELEGRAM_CLIENT_BOT_TOKEN" => "client-token"
      )
    end

    assert_includes error.message, "TELEGRAM_BROKER_BOT_TOKEN"
    assert_includes error.message, "TELEGRAM_WEBHOOK_BASE_URL"
  end

  def test_builds_https_endpoints_and_derived_secrets
    config = configuration

    assert_equal "https://example.test/telegram/client", config.endpoint("client")
    assert_equal "https://example.test/telegram/broker", config.endpoint("broker")
    assert_match(/\A[a-f0-9]{64}\z/, config.secret_token("client"))
    refute_equal config.secret_token("client"), config.secret_token("broker")
  end

  def test_bot_api_sends_structured_requests_without_exposing_transport_details
    requests = []
    transport = ->(method, payload) do
      requests << [method, payload]
      true
    end
    api = ZeroXDA::Market::Telegram::BotAPI.new(
      token: "token",
      transport: transport
    )

    api.send_message(
      chat_id: 7,
      text: "hello",
      reply_markup: { "inline_keyboard" => [] }
    )
    api.set_webhook(url: configuration.endpoint("client"), secret_token: "secret")

    assert_equal "sendMessage", requests.fetch(0).fetch(0)
    assert_equal "7", requests.fetch(0).fetch(1).fetch(:chat_id)
    assert requests.fetch(0).fetch(1).dig(:link_preview_options, :is_disabled)
    assert_equal "setWebhook", requests.fetch(1).fetch(0)
    assert_equal %w[message callback_query], requests.fetch(1).fetch(1).fetch(:allowed_updates)
  end

  private

  def configuration
    ZeroXDA::Market::Telegram::Configuration.new(
      client_token: "client-token",
      broker_token: "broker-token",
      base_url: "https://example.test/"
    )
  end
end
