# frozen_string_literal: true

require "json"
require "rack"
require "time"
require_relative "../core/contracts"
require_relative "bearer_auth"

module ZeroXDA
  module Market
    module Transport
      class ManualAPI
        MAX_BODY_BYTES = 1_048_576
        JSON_HEADERS = {
          "content-type" => "application/json; charset=utf-8",
          "cache-control" => "no-store"
        }.freeze
        REQUIRED_TASK_METHODS = %i[tasks fetch_task complete_task claim_task reject_task].freeze

        def initialize(provider:, token:, identity_service: nil, catalog: nil)
          @provider = validate_task_service!(provider)
          @authentication = BearerAuth.new(token: token)
          @identity_service = identity_service
          @catalog = catalog
        end

        def call(environment)
          request = Rack::Request.new(environment)
          unless @authentication.authorized?(request)
            return error_response(401, "unauthorized", "operator authentication failed")
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
        rescue Core::Conflict => error
          core_error_response(409, error)
        rescue ArgumentError => error
          error_response(422, "validation_error", error.message)
        rescue StandardError
          error_response(500, "internal_error", "the server could not process the request")
        end

        private

        def route(request)
          method = request.request_method
          path = request.path_info

          if method == "GET" && path == "/v1/tasks"
            tasks = @provider.tasks(status: request.params["status"])
            return json_response(200, { "data" => tasks.map { |task| present_task(task) } })
          end

          if method == "GET" && path == "/v1/products" && @catalog
            locale = request.params["locale"].to_s
            locale = "en_US" if locale.empty?
            products = @catalog.products(locale: locale)
            return json_response(
              200,
              {
                "data" => products.map { |product| present_product(product) },
                "meta" => {
                  "count" => products.length,
                  "locale" => products.first&.locale || "en_US"
                }
              }
            )
          end

          if method == "POST" && path == "/v1/auth/external" && @identity_service
            body = request_document(request)
            authentication = @identity_service.authenticate(
              provider: body.fetch("provider"),
              provider_user_id: body.fetch("provider_user_id"),
              provider_data: body.fetch("provider_data", {}),
              role: "broker"
            )
            status = authentication.created ? 201 : 200
            return json_response(
              status,
              { "data" => present_authentication(authentication) }
            )
          end

          if (match = path.match(%r{\A/v1/tasks/([^/]+)\z}))
            return resource_response(200, @provider.fetch_task(match[1])) if method == "GET"
          end

          if (match = path.match(%r{\A/v1/tasks/([^/]+)/complete\z}))
            if method == "POST"
              body = request_document(request)
              task = @provider.complete_task(
                match[1],
                reference: body["reference"],
                data: body.fetch("data", {})
              )
              return resource_response(200, task)
            end
          end

          if (match = path.match(%r{\A/v1/tasks/([^/]+)/claim\z}))
            if method == "POST"
              body = request_document(request)
              task = @provider.claim_task(match[1], assignee: body.fetch("assignee"))
              return resource_response(200, task)
            end
          end

          if (match = path.match(%r{\A/v1/tasks/([^/]+)/reject\z}))
            if method == "POST"
              body = request_document(request)
              task = @provider.reject_task(
                match[1],
                message: body.fetch("message"),
                code: body.fetch("code", "manual_rejection"),
                details: body.fetch("details", {})
              )
              return resource_response(200, task)
            end
          end

          error_response(404, "route_not_found", "route was not found")
        end

        def validate_task_service!(service)
          missing = REQUIRED_TASK_METHODS.reject { |method_name| service.respond_to?(method_name) }
          return service if missing.empty?

          raise ArgumentError, "task service is missing methods: #{missing.join(", ")}"
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

        def present_task(task)
          {
            "type" => "manual_task",
            "id" => task.id,
            "attributes" => {
              "order_id" => task.order_id,
              "capability" => task.capability,
              "payload" => task.payload,
              "context" => task.context,
              "terms" => task.terms,
              "status" => task.status,
              "claimed_by" => task.claimed_by,
              "result" => task.result,
              "failure" => task.failure,
              "created_at" => timestamp(task.created_at),
              "updated_at" => timestamp(task.updated_at)
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
              "position" => product.position
            }
          }
        end

        def timestamp(value)
          value.iso8601(6)
        end

        def resource_response(status, task)
          json_response(status, { "data" => present_task(task) })
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
