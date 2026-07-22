# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/transport/json_api"

class JSONAPIContractTest < Minitest::Test
  include KernelFixture

  def setup
    clock = MutableClock.new
    provider = TestProvider.new(clock: clock)
    kernel, = build_kernel(provider: provider, clock: clock)
    @client = Rack::MockRequest.new(ZeroXDA::Market::Transport::JSONAPI.new(kernel: kernel))
  end

  def test_unknown_routes_and_wrong_methods_keep_the_same_error_document
    [@client.get("/unknown"), @client.get("/v1/intents")].each do |response|
      assert_equal 404, response.status
      assert_equal "application/json; charset=utf-8", response["content-type"]
      assert_equal "no-store", response["cache-control"]
      assert_equal(
        {
          "errors" => [
            {
              "code" => "route_not_found",
              "message" => "route was not found",
              "details" => {}
            }
          ]
        },
        JSON.parse(response.body)
      )
    end
  end

  def test_authentication_still_runs_before_route_not_found
    clock = MutableClock.new
    provider = TestProvider.new(clock: clock)
    kernel, = build_kernel(provider: provider, clock: clock)
    client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(kernel: kernel, token: "client-secret")
    )

    response = client.get("/unknown")

    assert_equal 401, response.status
    assert_equal "unauthorized", JSON.parse(response.body).dig("errors", 0, "code")
  end

  def test_request_validation_contract_is_unchanged
    response = @client.post(
      "/v1/intents",
      "CONTENT_TYPE" => "text/plain",
      input: "{}"
    )

    assert_equal 422, response.status
    error = JSON.parse(response.body).fetch("errors").first
    assert_equal "validation_error", error.fetch("code")
    assert_equal "content type must be application/json", error.fetch("message")
    assert_equal({}, error.fetch("details"))
  end

  def test_missing_fields_keep_their_field_detail
    response = @client.post(
      "/v1/intents",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(capability: "anything.operation")
    )

    assert_equal 400, response.status
    error = JSON.parse(response.body).fetch("errors").first
    assert_equal "missing_field", error.fetch("code")
    assert_equal({ "field" => "payload" }, error.fetch("details"))
  end
end
