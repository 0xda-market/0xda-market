# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"

class RuntimeTest < Minitest::Test
  def test_starts_in_health_only_mode_without_an_operator_token
    with_environment(
      "RACK_ENV" => nil,
      "PUBLIC_API_TOKEN" => nil,
      "MANUAL_PROVIDER_TOKEN" => nil,
      "DATABASE_URL" => nil,
      "TELEGRAM_CLIENT_BOT_TOKEN" => nil,
      "TELEGRAM_BROKER_BOT_TOKEN" => nil,
      "TELEGRAM_WEBHOOK_BASE_URL" => nil
    ) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))

      health = Rack::MockRequest.new(app).get("/health")
      assert_equal 200, health.status

      intent = post_json(
        app,
        "/v1/intents",
        { capability: "manual.fulfillment", payload: {} }
      )
      assert_equal 422, intent.status
    end
  end

  def test_mounts_manual_provider_when_an_operator_token_is_configured
    with_environment(
      "RACK_ENV" => "development",
      "PUBLIC_API_TOKEN" => "client-secret",
      "MANUAL_PROVIDER_TOKEN" => "operator-secret",
      "DATABASE_URL" => nil,
      "TELEGRAM_CLIENT_BOT_TOKEN" => nil,
      "TELEGRAM_BROKER_BOT_TOKEN" => nil,
      "TELEGRAM_WEBHOOK_BASE_URL" => nil
    ) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))

      intent = post_json(
        app,
        "/v1/intents",
        { capability: "manual.fulfillment", payload: { action: "deliver" } },
        authorization: "Bearer client-secret"
      )
      assert_equal 201, intent.status

      public_unauthorized = post_json(
        app,
        "/v1/intents",
        { capability: "manual.fulfillment", payload: {} }
      )
      assert_equal 401, public_unauthorized.status

      unauthorized = Rack::MockRequest.new(app).get("/operator/v1/tasks")
      assert_equal 401, unauthorized.status
    end
  end

  def test_mounts_both_telegram_webhooks_when_the_bots_are_configured
    with_environment(
      "RACK_ENV" => "development",
      "PUBLIC_API_TOKEN" => "client-secret",
      "MANUAL_PROVIDER_TOKEN" => "operator-secret",
      "DATABASE_URL" => nil,
      "TELEGRAM_CLIENT_BOT_TOKEN" => "client-bot-token",
      "TELEGRAM_BROKER_BOT_TOKEN" => "broker-bot-token",
      "TELEGRAM_WEBHOOK_BASE_URL" => "https://example.test"
    ) do
      app = Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      client = Rack::MockRequest.new(app)

      assert_equal 405, client.get("/telegram/client").status
      assert_equal 405, client.get("/telegram/broker").status
    end
  end

  def test_rejects_production_boot_with_missing_secrets
    with_environment(
      "RACK_ENV" => "production",
      "PUBLIC_API_TOKEN" => nil,
      "MANUAL_PROVIDER_TOKEN" => nil,
      "DATABASE_URL" => nil,
      "TELEGRAM_CLIENT_BOT_TOKEN" => nil,
      "TELEGRAM_BROKER_BOT_TOKEN" => nil,
      "TELEGRAM_WEBHOOK_BASE_URL" => nil
    ) do
      error = assert_raises(RuntimeError) do
        Rack::Builder.parse_file(File.expand_path("../config.ru", __dir__))
      end

      assert_includes error.message, "PUBLIC_API_TOKEN"
      assert_includes error.message, "MANUAL_PROVIDER_TOKEN"
      assert_includes error.message, "DATABASE_URL"
      assert_includes error.message, "TELEGRAM_CLIENT_BOT_TOKEN"
      assert_includes error.message, "TELEGRAM_BROKER_BOT_TOKEN"
      assert_includes error.message, "TELEGRAM_WEBHOOK_BASE_URL"
    end
  end

  private

  def with_environment(changes)
    previous = changes.to_h { |name, _value| [name, ENV[name]] }
    changes.each do |name, value|
      if value
        ENV[name] = value
      else
        ENV.delete(name)
      end
    end
    yield
  ensure
    previous.each do |name, value|
      if value
        ENV[name] = value
      else
        ENV.delete(name)
      end
    end
  end

  def post_json(app, path, body, authorization: nil)
    headers = { "CONTENT_TYPE" => "application/json" }
    headers["HTTP_AUTHORIZATION"] = authorization if authorization
    headers[:input] = JSON.generate(body)
    Rack::MockRequest.new(app).post(path, headers)
  end
end
