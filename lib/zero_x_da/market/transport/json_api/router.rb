# frozen_string_literal: true

require "rack"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        class Router
          Route = Struct.new(:handler, :params, :public, keyword_init: true) do
            def public?
              public
            end
          end

          def initialize(authentication:, error_mapper:, endpoint_handler:)
            @authentication = authentication
            @error_mapper = error_mapper
            @endpoint_handler = endpoint_handler
          end

          def call(environment)
            @error_mapper.call do
              request = Rack::Request.new(environment)
              route = resolve(request)

              if route.public? || authorized?(request)
                @endpoint_handler.public_send(route.handler, request, **route.params)
              else
                @error_mapper.unauthorized
              end
            end
          end

          private

          def authorized?(request)
            !@authentication || @authentication.authorized?(request)
          end

          def resolve(request)
            method = request.request_method
            path = request.path_info

            return route(:health, public: true) if method == "GET" && path == "/health"
            if method == "POST" && path == "/v1/auth/external" && available?(:authenticate_external)
              return route(:authenticate_external)
            end
            if method == "GET" && path == "/v1/products" && available?(:products)
              return route(:products)
            end
            if method == "GET" && path == "/v1/currencies" && available?(:currencies)
              return route(:currencies)
            end
            if method == "GET" && path == "/v1/admin/prices/proposal" && available?(:price_proposal)
              return route(:price_proposal)
            end
            if method == "POST" && path == "/v1/admin/prices" && available?(:apply_prices)
              return route(:apply_prices)
            end
            if method == "GET" && path == "/v1/users" && available?(:users)
              return route(:users)
            end
            if method == "POST" && path == "/v1/admin/users/set-admin" && available?(:assign_admin)
              return route(:assign_admin)
            end
            return route(:create_intent) if method == "POST" && path == "/v1/intents"

            if method == "GET" && (match = path.match(%r{\A/v1/intents/([^/]+)\z}))
              return route(:find_intent, id: match[1])
            end
            if method == "POST" && (match = path.match(%r{\A/v1/intents/([^/]+)/quotes\z}))
              return route(:quote_intent, id: match[1])
            end
            if method == "GET" && (match = path.match(%r{\A/v1/quotes/([^/]+)\z}))
              return route(:find_quote, id: match[1])
            end
            if method == "POST" && (match = path.match(%r{\A/v1/quotes/([^/]+)/accept\z}))
              return route(:accept_quote, id: match[1])
            end
            if method == "GET" && (match = path.match(%r{\A/v1/orders/([^/]+)\z}))
              return route(:find_order, id: match[1])
            end
            if method == "POST" && (match = path.match(%r{\A/v1/orders/([^/]+)/execute\z}))
              return route(:execute_order, id: match[1])
            end
            if method == "POST" && (match = path.match(%r{\A/v1/orders/([^/]+)/cancel\z}))
              return route(:cancel_order, id: match[1])
            end

            route(:not_found)
          end

          def available?(endpoint)
            @endpoint_handler.available?(endpoint)
          end

          def route(handler, public: false, **params)
            Route.new(handler: handler, params: params, public: public)
          end
        end
      end
    end
  end
end
