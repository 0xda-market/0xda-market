# frozen_string_literal: true

require "json"
require "rack"
require "time"
require_relative "../core/kernel"
require_relative "bearer_auth"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        MAX_BODY_BYTES = 1_048_576
        JSON_HEADERS = {
          "content-type" => "application/json; charset=utf-8",
          "cache-control" => "no-store"
        }.freeze

        def initialize(kernel:, token: nil, readiness: -> { true })
          @kernel = kernel
          @authentication = token && BearerAuth.new(token: token)
          @readiness = readiness
        end

        def call(environment)
          request = Rack::Request.new(environment)
          unless public_route?(request) || authorized?(request)
            return error_response(401, "unauthorized", "client authentication failed")
          end

          route(request)
        rescue JSON::ParserError
          error_response(400, "invalid_json", "request body is not valid JSON")
        rescue KeyError => error
          error_response(
            400,
            "missing_field",
            "request is missing a required field",
            { "field" => error.key.to_s }
          )
        rescue Core::NotFound => error
          core_error_response(404, error)
        rescue Core::UnknownCapability, ArgumentError => error
          if error.is_a?(Core::Error)
            core_error_response(422, error)
          else
            error_response(422, "validation_error", error.message)
          end
        rescue Core::Conflict => error
          core_error_response(409, error)
        rescue Core::ProviderFailure => error
          core_error_response(502, error)
        rescue StandardError
          error_response(500, "internal_error", "the server could not process the request")
        end

        private

        def public_route?(request)
          request.get? && request.path_info == "/health"
        end

        def authorized?(request)
          !@authentication || @authentication.authorized?(request)
        end

        def route(request)
          method = request.request_method
          path = request.path_info

          if method == "GET" && path == "/health"
            ready = @readiness.call
            return json_response(ready ? 200 : 503, { "status" => ready ? "ok" : "unavailable" })
          end

          if method == "POST" && path == "/v1/intents"
            body = request_document(request)
            intent = @kernel.create_intent(
              capability: body.fetch("capability"),
              payload: body.fetch("payload"),
              context: body.fetch("context", {})
            )
            return resource_response(201, present_intent(intent))
          end

          if (match = path.match(%r{\A/v1/intents/([^/]+)\z}))
            return resource_response(200, present_intent(@kernel.find_intent(match[1]))) if method == "GET"
          end

          if (match = path.match(%r{\A/v1/intents/([^/]+)/quotes\z}))
            if method == "POST"
              ensure_empty_or_object_body(request)
              return resource_response(201, present_quote(@kernel.quote_intent(match[1])))
            end
          end

          if (match = path.match(%r{\A/v1/quotes/([^/]+)\z}))
            return resource_response(200, present_quote(@kernel.find_quote(match[1]))) if method == "GET"
          end

          if (match = path.match(%r{\A/v1/quotes/([^/]+)/accept\z}))
            if method == "POST"
              ensure_empty_or_object_body(request)
              return resource_response(201, present_order(@kernel.accept_quote(match[1])))
            end
          end

          if (match = path.match(%r{\A/v1/orders/([^/]+)\z}))
            return resource_response(200, present_order(@kernel.find_order(match[1]))) if method == "GET"
          end

          if (match = path.match(%r{\A/v1/orders/([^/]+)/execute\z}))
            if method == "POST"
              ensure_empty_or_object_body(request)
              return resource_response(200, present_order(@kernel.execute_order(match[1])))
            end
          end

          if (match = path.match(%r{\A/v1/orders/([^/]+)/cancel\z}))
            if method == "POST"
              ensure_empty_or_object_body(request)
              return resource_response(200, present_order(@kernel.cancel_order(match[1])))
            end
          end

          error_response(404, "route_not_found", "route was not found")
        end

        def request_document(request)
          media_type = request.media_type
          unless media_type == "application/json" || media_type&.end_with?("+json")
            raise ArgumentError, "content type must be application/json"
          end

          raw = request.body.read(MAX_BODY_BYTES + 1)
          raise ArgumentError, "request body is too large" if raw.bytesize > MAX_BODY_BYTES

          Core::RecordSupport.document(JSON.parse(raw), field: "request")
        end

        def ensure_empty_or_object_body(request)
          return {} if request.content_length.to_i.zero?

          request_document(request)
        end

        def present_intent(intent)
          {
            "type" => "intent",
            "id" => intent.id,
            "attributes" => {
              "capability" => intent.capability,
              "payload" => intent.payload,
              "context" => intent.context,
              "created_at" => timestamp(intent.created_at)
            }
          }
        end

        def present_quote(quote)
          {
            "type" => "quote",
            "id" => quote.id,
            "attributes" => {
              "intent_id" => quote.intent_id,
              "terms" => quote.terms,
              "expires_at" => timestamp(quote.expires_at),
              "created_at" => timestamp(quote.created_at)
            }
          }
        end

        def present_order(order)
          {
            "type" => "order",
            "id" => order.id,
            "attributes" => {
              "intent_id" => order.intent_id,
              "quote_id" => order.quote_id,
              "capability" => order.capability,
              "payload" => order.payload,
              "context" => order.context,
              "terms" => order.terms,
              "status" => order.status,
              "attempts" => order.attempts,
              "progress" => order.progress,
              "result" => order.result,
              "failure" => order.failure,
              "created_at" => timestamp(order.created_at),
              "updated_at" => timestamp(order.updated_at)
            }
          }
        end

        def timestamp(value)
          value&.iso8601(6)
        end

        def resource_response(status, resource)
          json_response(status, { "data" => resource })
        end

        def core_error_response(status, error)
          error_response(status, error.code, error.message, error.details)
        end

        def error_response(status, code, message, details = {})
          json_response(
            status,
            {
              "errors" => [
                {
                  "code" => code,
                  "message" => message,
                  "details" => details
                }
              ]
            }
          )
        end

        def json_response(status, document)
          [status, JSON_HEADERS, [JSON.generate(document)]]
        end
      end
    end
  end
end
