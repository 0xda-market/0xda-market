# frozen_string_literal: true

require "time"
require_relative "../../localization/service"
require_relative "response"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        class EndpointHandler
          include Response

          def initialize(
            kernel:,
            readiness:,
            request_parser:,
            identity_service: nil,
            admin_service: nil,
            catalog: nil,
            pricing: nil,
            localization: nil
          )
            @kernel = kernel
            @readiness = readiness
            @request_parser = request_parser
            @identity_service = identity_service
            @admin_service = admin_service
            @catalog = catalog
            @pricing = pricing
            @localization = localization
          end

          def available?(endpoint)
            case endpoint
            when :authenticate_external, :users
              !@identity_service.nil?
            when :products, :currencies
              !@catalog.nil?
            when :price_proposal, :apply_prices
              !@pricing.nil? && !@admin_service.nil?
            when :assign_admin
              !@admin_service.nil?
            else
              true
            end
          end

          def health(_request)
            ready = @readiness.call
            json_response(
              ready ? 200 : 503,
              {
                "status" => ready ? "ok" : "unavailable",
                "server_time" => Time.now.utc.iso8601(6)
              }
            )
          end

          def authenticate_external(request)
            body = @request_parser.request_document(request)
            authentication = @identity_service.authenticate(
              provider: body.fetch("provider"),
              provider_user_id: body.fetch("provider_user_id"),
              provider_data: body.fetch("provider_data", {})
            )
            status = authentication.created ? 201 : 200
            resource_response(status, present_authentication(authentication))
          end

          def products(request)
            currency = @request_parser.requested_currency(request)
            locale = @request_parser.requested_locale(request)
            products = @catalog.products(locale: locale)
            prices = @pricing ? @pricing.current_prices : {}
            data = products.map do |product|
              resource = present_product(product)
              price = prices[product.sku]
              resource["attributes"]["price"] = price && present_localized_price(price, currency)
              resource
            end
            json_response(
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

          def currencies(request)
            locale = @request_parser.requested_locale(request)
            currencies = @catalog.currencies(locale: locale)
            data = currencies.map { |currency| present_currency(currency) }
            json_response(
              200,
              {
                "data" => data,
                "meta" => {
                  "count" => currencies.length,
                  "base_currency" => Localization::Service::BASE_CURRENCY,
                  "locale" => locale
                }
              }
            )
          end

          def price_proposal(request)
            @admin_service.require_admin(user_id: request.params["actor_user_id"])
            locale = @request_parser.requested_locale(request)
            entries = @pricing.proposal(locale: locale)
            json_response(
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

          def apply_prices(request)
            body = @request_parser.request_document(request)
            actor_user = @admin_service.require_admin(user_id: body.fetch("actor_user_id"))
            entries = body.fetch("prices")
            raise ArgumentError, "prices must be a non-empty array" unless entries.is_a?(Array)

            applied = @pricing.apply_prices(
              entries,
              source: "admin",
              set_by_user_id: actor_user.id
            )
            json_response(
              201,
              {
                "data" => applied.map { |price| present_price(price) },
                "meta" => { "count" => applied.length }
              }
            )
          end

          def users(request)
            unless request.params["status"] == "active"
              raise ArgumentError, "status must be active"
            end

            users = @identity_service.active_users
            json_response(
              200,
              {
                "data" => users.map { |profile| present_user_profile(profile) },
                "meta" => { "count" => users.length }
              }
            )
          end

          def assign_admin(request)
            body = @request_parser.request_document(request)
            assignment = @admin_service.assign_admin(
              actor_user_id: body.fetch("actor_user_id"),
              target_user_id: body.fetch("target_user_id")
            )
            resource_response(200, present_role_assignment(assignment))
          end

          def create_intent(request)
            body = @request_parser.request_document(request)
            intent = @kernel.create_intent(
              capability: body.fetch("capability"),
              payload: body.fetch("payload"),
              context: body.fetch("context", {})
            )
            resource_response(201, present_intent(intent))
          end

          def find_intent(_request, id:)
            resource_response(200, present_intent(@kernel.find_intent(id)))
          end

          def quote_intent(request, id:)
            @request_parser.ensure_empty_or_object_body(request)
            resource_response(201, present_quote(@kernel.quote_intent(id)))
          end

          def find_quote(_request, id:)
            resource_response(200, present_quote(@kernel.find_quote(id)))
          end

          def accept_quote(request, id:)
            @request_parser.ensure_empty_or_object_body(request)
            resource_response(201, present_order(@kernel.accept_quote(id)))
          end

          def find_order(_request, id:)
            resource_response(200, present_order(@kernel.find_order(id)))
          end

          def execute_order(request, id:)
            @request_parser.ensure_empty_or_object_body(request)
            resource_response(200, present_order(@kernel.execute_order(id)))
          end

          def cancel_order(request, id:)
            @request_parser.ensure_empty_or_object_body(request)
            resource_response(200, present_order(@kernel.cancel_order(id)))
          end

          def not_found(_request)
            json_response(
              404,
              {
                "errors" => [
                  {
                    "code" => "route_not_found",
                    "message" => "route was not found",
                    "details" => {}
                  }
                ]
              }
            )
          end

          private

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
            {
              "type" => "user",
              "id" => user.id,
              "attributes" => {
                "role" => user.role,
                "status" => user.status,
                "created_at" => timestamp(user.created_at),
                "updated_at" => timestamp(user.updated_at),
                "identity" => present_identity(authentication.identity)
              },
              "meta" => { "created" => authentication.created }
            }
          end

          def present_user_profile(profile)
            {
              "type" => "user",
              "id" => profile.user.id,
              "attributes" => {
                "role" => profile.user.role,
                "status" => profile.user.status,
                "identities" => profile.identities.map { |identity| present_identity(identity) }
              }
            }
          end

          def present_identity(identity)
            {
              "provider" => identity.provider,
              "provider_user_id" => identity.provider_user_id,
              "provider_data" => identity.provider_data,
              "last_authenticated_at" => timestamp(identity.last_authenticated_at)
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

          def present_currency(currency)
            resource = present_product(currency)
            resource["type"] = "currency"
            resource["attributes"]["code"] = currency.currency_code
            resource["attributes"]["usdt_per_unit"] =
              currency.current_price_usdt && decimal_string(currency.current_price_usdt)
            resource
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
                "role" => assignment.user.role,
                "status" => assignment.user.status
              },
              "meta" => {
                "changed" => assignment.changed,
                "assigned_by" => assignment.actor.id
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

          def decimal_string(value)
            value.to_s("F")
          end

          def timestamp(value)
            value&.iso8601(6)
          end
        end
      end
    end
  end
end
