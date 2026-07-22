# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rack/mock"
require "zero_x_da/market/transport/json_api/error_mapper"
require "zero_x_da/market/transport/json_api/router"

class JSONAPIRouterTest < Minitest::Test
  class Authentication
    def initialize(authorized)
      @authorized = authorized
    end

    def authorized?(_request)
      @authorized
    end
  end

  class EndpointHandler
    attr_reader :calls

    def initialize(available: {}, error: nil)
      @available = available
      @error = error
      @calls = []
    end

    def available?(endpoint)
      @available.fetch(endpoint, true)
    end

    def method_missing(name, _request, **params)
      raise @error if @error

      @calls << [name, params]
      [200, { "content-type" => "application/json" }, [JSON.generate(params)]]
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  ROUTES = [
    ["GET", "/health", :health, {}],
    ["POST", "/v1/auth/external", :authenticate_external, {}],
    ["GET", "/v1/products", :products, {}],
    ["GET", "/v1/currencies", :currencies, {}],
    ["GET", "/v1/admin/prices/proposal", :price_proposal, {}],
    ["POST", "/v1/admin/prices", :apply_prices, {}],
    ["GET", "/v1/users", :users, {}],
    ["POST", "/v1/admin/users/set-admin", :assign_admin, {}],
    ["POST", "/v1/intents", :create_intent, {}],
    ["GET", "/v1/intents/intent-1", :find_intent, { id: "intent-1" }],
    ["POST", "/v1/intents/intent-1/quotes", :quote_intent, { id: "intent-1" }],
    ["GET", "/v1/quotes/quote-1", :find_quote, { id: "quote-1" }],
    ["POST", "/v1/quotes/quote-1/accept", :accept_quote, { id: "quote-1" }],
    ["GET", "/v1/orders/order-1", :find_order, { id: "order-1" }],
    ["POST", "/v1/orders/order-1/execute", :execute_order, { id: "order-1" }],
    ["POST", "/v1/orders/order-1/cancel", :cancel_order, { id: "order-1" }]
  ].freeze

  def test_dispatches_every_existing_route_to_its_endpoint_handler
    handler = EndpointHandler.new
    router = build_router(handler: handler)

    ROUTES.each do |method, path, expected_handler, expected_params|
      response = router.call(environment(method, path))

      assert_equal 200, response[0], "#{method} #{path}"
      assert_equal [expected_handler, expected_params], handler.calls.last, "#{method} #{path}"
    end
  end

  def test_wrong_method_and_unknown_path_dispatch_to_not_found
    handler = EndpointHandler.new
    router = build_router(handler: handler)

    router.call(environment("GET", "/v1/intents"))
    assert_equal [:not_found, {}], handler.calls.last

    router.call(environment("GET", "/unknown"))
    assert_equal [:not_found, {}], handler.calls.last
  end

  def test_disabled_optional_endpoint_is_indistinguishable_from_an_unknown_route
    handler = EndpointHandler.new(available: { products: false })
    router = build_router(handler: handler)

    router.call(environment("GET", "/v1/products"))

    assert_equal [:not_found, {}], handler.calls.last
  end

  def test_health_is_public_but_every_other_route_is_authenticated_before_dispatch
    handler = EndpointHandler.new
    router = build_router(handler: handler, authentication: Authentication.new(false))

    health = router.call(environment("GET", "/health"))
    unauthorized = router.call(environment("GET", "/unknown"))

    assert_equal 200, health[0]
    assert_equal [:health, {}], handler.calls.last
    assert_equal 401, unauthorized[0]
    assert_equal "unauthorized", JSON.parse(unauthorized[2].join).dig("errors", 0, "code")
    assert_equal 1, handler.calls.length
  end

  def test_handler_failures_are_mapped_at_the_router_boundary
    handler = EndpointHandler.new(error: ZeroXDA::Market::Core::Conflict.new("already changed"))
    router = build_router(handler: handler)

    response = router.call(environment("POST", "/v1/intents"))

    assert_equal 409, response[0]
    assert_equal "conflict", JSON.parse(response[2].join).dig("errors", 0, "code")
  end

  private

  def build_router(handler:, authentication: nil)
    ZeroXDA::Market::Transport::JSONAPI::Router.new(
      authentication: authentication,
      error_mapper: ZeroXDA::Market::Transport::JSONAPI::ErrorMapper.new,
      endpoint_handler: handler
    )
  end

  def environment(method, path)
    Rack::MockRequest.env_for(path, method: method)
  end
end
