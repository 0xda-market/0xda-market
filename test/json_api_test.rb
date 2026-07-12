# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "zero_x_da/market/transport/json_api"

class JSONAPITest < Minitest::Test
  include KernelFixture

  def setup
    clock = MutableClock.new
    @provider = TestProvider.new(clock: clock)
    kernel, = build_kernel(provider: @provider, clock: clock)
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(kernel: kernel)
    )
  end

  def test_complete_http_lifecycle_hides_private_provider_state
    intent = resource(
      post_json(
        "/v1/intents",
        {
          capability: "anything.operation",
          payload: { arbitrary: { shape: [1, 2, 3] } },
          context: { actor: "opaque-actor" }
        }
      ),
      expected_status: 201
    )
    quote = resource(
      post_json("/v1/intents/#{intent.fetch("id")}/quotes", {}),
      expected_status: 201
    )
    refute quote.fetch("attributes").key?("private_state")

    order = resource(
      post_json("/v1/quotes/#{quote.fetch("id")}/accept", {}),
      expected_status: 201
    )
    result = resource(
      post_json("/v1/orders/#{order.fetch("id")}/execute", {}),
      expected_status: 200
    )

    assert_equal "succeeded", result.dig("attributes", "status")
    refute result.fetch("attributes").key?("private_state")
  end

  def test_health_endpoint
    response = @client.get("/health")

    assert_equal 200, response.status
    document = JSON.parse(response.body)
    assert_equal "ok", document.fetch("status")
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, document.fetch("server_time"))
  end

  def test_health_endpoint_reports_unavailable_when_storage_is_not_ready
    clock = MutableClock.new
    provider = TestProvider.new(clock: clock)
    kernel, = build_kernel(provider: provider, clock: clock)
    client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: kernel,
        readiness: -> { false }
      )
    )

    response = client.get("/health")

    assert_equal 503, response.status
    document = JSON.parse(response.body)
    assert_equal "unavailable", document.fetch("status")
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, document.fetch("server_time"))
  end

  def test_bearer_auth_protects_the_api_but_not_health
    clock = MutableClock.new
    provider = TestProvider.new(clock: clock)
    kernel, = build_kernel(provider: provider, clock: clock)
    client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: kernel,
        token: "client-secret"
      )
    )

    assert_equal 200, client.get("/health").status

    unauthorized = post_json_with(
      client,
      "/v1/intents",
      capability: "anything.operation",
      payload: {}
    )
    assert_equal 401, unauthorized.status
    assert_equal "unauthorized", JSON.parse(unauthorized.body).dig("errors", 0, "code")

    authorized = client.post(
      "/v1/intents",
      "HTTP_AUTHORIZATION" => "Bearer client-secret",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(capability: "anything.operation", payload: {})
    )
    assert_equal 201, authorized.status
  end

  def test_exposes_deferred_execution_progress
    clock = MutableClock.new
    provider = TestProvider.new(clock: clock) do |_order, _idempotency_key|
      ZeroXDA::Market::Core::Contracts::PendingResult.new(
        reference: "task-1",
        data: { status: "awaiting_operator" }
      )
    end
    kernel, = build_kernel(provider: provider, clock: clock)
    client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(kernel: kernel)
    )
    intent = resource(
      post_json_with(client, "/v1/intents", capability: "anything.operation", payload: {}),
      expected_status: 201
    )
    quote = resource(
      post_json_with(client, "/v1/intents/#{intent.fetch("id")}/quotes", {}),
      expected_status: 201
    )
    order = resource(
      post_json_with(client, "/v1/quotes/#{quote.fetch("id")}/accept", {}),
      expected_status: 201
    )

    pending = resource(
      post_json_with(client, "/v1/orders/#{order.fetch("id")}/execute", {}),
      expected_status: 200
    )

    assert_equal "pending", pending.dig("attributes", "status")
    assert_equal "task-1", pending.dig("attributes", "progress", "reference")
  end

  def test_reports_invalid_json
    response = @client.post(
      "/v1/intents",
      "CONTENT_TYPE" => "application/json",
      input: "{"
    )

    assert_equal 400, response.status
    assert_equal "invalid_json", JSON.parse(response.body).dig("errors", 0, "code")
  end

  def test_reports_unknown_capability
    response = post_json(
      "/v1/intents",
      { capability: "unknown.operation", payload: {} }
    )

    assert_equal 422, response.status
    assert_equal "unknown_capability", JSON.parse(response.body).dig("errors", 0, "code")
  end

  private

  def post_json(path, body)
    post_json_with(@client, path, body)
  end

  def post_json_with(client, path, body)
    client.post(
      path,
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(body)
    )
  end

  def resource(response, expected_status:)
    assert_equal expected_status, response.status, response.body
    JSON.parse(response.body).fetch("data")
  end
end
