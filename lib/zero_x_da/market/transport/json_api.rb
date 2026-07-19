# frozen_string_literal: true

require "json"
require "rack"
require "time"
require_relative "../core/kernel"
require_relative "../localization/service"
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

        def initialize(
          kernel:,
          token: nil,
          readiness: -> { true },
          identity_service: nil,
          catalog: nil,
          pricing: nil,
          localization: nil
        )
          @kernel = kernel
          @authentication = token && BearerAuth.new(token: token)
          @readiness = readiness
          @identity_service = identity_service
          @catalog = catalog
          @pricing = pricing
          @localization = localization
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
        rescue Core::Forbidden => error
          core_error_response(403, error)
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
            return json_response(
              ready ? 200 : 503,
              {
                "status" => ready ? "ok" : "unavailable",
                "server_time" => Time.now.utc.iso8601(6)
              }
            )
          end

          if method == "POST" && path == "/v1/auth/telegram" && @identity_service
            body = request_document(request)
            authentication = @identity_service.authenticate(
              provider_user_id: body.fetch("telegram_user_id"),
              provider_data: telegram_provider_data(body)
            )
            status = authentication.created ? 201 : 200
            return resource_response(status, present_authentication(authentication))
          end

          if method == "GET" && path == "/v1/products" && @catalog
            currency = requested_currency(request)
            locale = requested_locale(request)
            products = @catalog.products(locale: locale)
            prices = @pricing ? @pricing.current_prices : {}
            data = products.map do |product|
              resource = present_product(product)
              price = prices[product.sku]
              resource["attributes"]["price"] = price && present_localized_price(price, currency)
              resource
            end
            return json_response(
              200,
              {
                "data" => data,
                "meta" => {
                  "count" => products.length,
                  "currency" => currency,
                  "locale" => locale
                }
              }
            )
          end

          if method == "GET" && path == "/v1/admin/prices/proposal" && @pricing && @identity_service
            @identity_service.require_admin(
              provider_user_id: request.params["actor_telegram_user_id"]
            )
            locale = requested_locale(request)
            entries = @pricing.proposal(locale: locale)
            return json_response(
              200,
              {
                "data" => entries.map { |entry| present_price_proposal(entry) },
                "meta" => {
                  "count" => entries.length,
                  "base_currency" => Localization::Service::BASE_CURRENCY,
                  "locale" => locale
                }
              }
            )
          end

          if method == "POST" && path == "/v1/admin/prices" && @pricing && @identity_service
            body = request_document(request)
            actor = body.fetch("actor_telegram_user_id")
            actor_user = @identity_service.require_admin(provider_user_id: actor)
            entries = body.fetch("prices")
            raise ArgumentError, "prices must be a non-empty array" unless entries.is_a?(Array)

            applied = @pricing.apply_prices(
              entries,
              source: "admin",
              set_by_user_id: actor_user.id
            )
            return json_response(
              201,
              {
                "data" => applied.map { |price| present_price(price) },
                "meta" => { "count" => applied.length }
              }
            )
          end

          if method == "GET" && path == "/v1/users" && @identity_service
            unless request.params["status"] == "active"
              raise ArgumentError, "status must be active"
            end

            users = @identity_service.active_users
            return json_response(
              200,
              {
                "data" => users.map { |entry| present_user_identity(entry) },
                "meta" => { "count" => users.length }
              }
            )
          end

          if method == "POST" && path == "/v1/admin/users/set-admin" && @identity_service
            body = request_document(request)
            assignment = @identity_service.set_admin(
              actor_provider_user_id: body.fetch("actor_telegram_user_id"),
              target: body.fetch("target")
            )
            return resource_response(200, present_role_assignment(assignment))
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

        # The requested display currency. Falls back to the base currency when
        # the parameter is absent or localization is not wired.
        def requested_currency(request)
          value = request.params["currency"].to_s.strip.upcase
          return Localization::Service::BASE_CURRENCY if value.empty? || @localization.nil?
          unless @localization.supported_currency?(value)
            raise ArgumentError, "currency is not supported: #{value}"
          end

          value
        end

        def requested_locale(request)
          value = request.params["locale"] || request.params["language_code"]
          return Localization::Service::DEFAULT_LOCALE unless @localization

          @localization.locale_for(value)
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

        def present_authentication(authentication)
          user = authentication.user
          identity = authentication.identity
          {
            "type" => "user",
            "id" => user.id,
            "attributes" => {
              "role" => user.role,
              "status" => user.status,
              "created_at" => timestamp(user.created_at),
              "updated_at" => timestamp(user.updated_at),
              "identity" => {
                "provider" => identity.provider,
                "provider_user_id" => identity.provider_user_id,
                "provider_data" => identity.provider_data,
                "last_authenticated_at" => timestamp(identity.last_authenticated_at)
              }
            },
            "meta" => { "created" => authentication.created }
          }
        end

        def present_user_identity(entry)
          {
            "type" => "user",
            "id" => entry.user.id,
            "attributes" => {
              "telegram_user_id" => entry.identity.provider_user_id,
              "role" => entry.user.role,
              "status" => entry.user.status,
              "locale" => if @localization
                              @localization.locale_for(
                                entry.identity.provider_data["language_code"]
                              )
                            else
                              Localization::Service::DEFAULT_LOCALE
                            end
            }
          }
        end

        def present_product(product)
          {
            "type" => "product",
            "id" => product.sku,
            "attributes" => {
              "name" => product.name,
              "short_name" => product.short_name,
              "button_label" => product.button_label,
              "locale" => product.locale,
              "metadata" => product.metadata,
              "status" => product.status,
              "position" => product.position,
              "updated_by_user_id" => product.updated_by_user_id,
              "price_updated_by_user_id" => product.price_updated_by_user_id,
              "price_updated_at" => timestamp(product.price_updated_at)
            }
          }
        end

        def present_localized_price(price, currency)
          amount = if @localization
                     @localization.convert(amount_usdt: price.amount_usdt, currency: currency)
                   else
                     price.amount_usdt
                   end
          {
            "amount" => decimal_string(amount),
            "currency" => currency,
            "amount_usdt" => decimal_string(price.amount_usdt),
            "source" => price.source,
            "edited_by_user_id" => price.set_by_user_id,
            "applied_at" => timestamp(price.created_at)
          }
        end

        def present_price(price)
          {
            "type" => "price",
            "id" => price.sku,
            "attributes" => {
              "sku" => price.sku,
              "amount_usdt" => decimal_string(price.amount_usdt),
              "source" => price.source,
              "edited_by_user_id" => price.set_by_user_id,
              "applied_at" => timestamp(price.created_at)
            }
          }
        end

        def present_price_proposal(entry)
          product = entry.fetch(:product)
          current = entry[:current]
          previous = entry[:previous]
          {
            "type" => "price_proposal",
            "id" => product.sku,
            "attributes" => {
              "name" => product.name,
              "short_name" => product.short_name,
              "button_label" => product.button_label,
              "locale" => product.locale,
              "position" => product.position,
              "current_amount_usdt" => current && decimal_string(current.amount_usdt),
              "current_applied_at" => current && timestamp(current.created_at),
              "current_edited_by_user_id" => current&.set_by_user_id,
              "previous_amount_usdt" => previous && decimal_string(previous.amount_usdt)
            }
          }
        end

        def present_role_assignment(assignment)
          {
            "type" => "user",
            "id" => assignment.user.id,
            "attributes" => {
              "telegram_user_id" => assignment.identity.provider_user_id,
              "telegram_chat_id" => assignment.identity.provider_data["chat_id"],
              "role" => assignment.user.role,
              "status" => assignment.user.status
            },
            "meta" => {
              "changed" => assignment.changed,
              "assigned_by" => assignment.actor.id
            }
          }
        end

        def telegram_provider_data(body)
          {
            "chat_id" => external_identifier(body.fetch("chat_id"), "chat_id"),
            "username" => optional_string(body["username"], "username"),
            "first_name" => optional_string(body["first_name"], "first_name"),
            "last_name" => optional_string(body["last_name"], "last_name"),
            "language_code" => optional_string(body["language_code"], "language_code")
          }.compact
        end

        def external_identifier(value, field)
          string = value.to_s
          raise ArgumentError, "#{field} must not be empty" if string.empty?
          raise ArgumentError, "#{field} is too long" if string.bytesize > 128

          string
        end

        def optional_string(value, field)
          return nil if value.nil?

          string = value.to_s
          raise ArgumentError, "#{field} is too long" if string.bytesize > 256

          string.empty? ? nil : string
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

        def decimal_string(value)
          value.to_s("F")
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
