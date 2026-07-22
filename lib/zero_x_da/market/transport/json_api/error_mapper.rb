# frozen_string_literal: true

require "json"
require_relative "../../core/contracts"
require_relative "response"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        class ErrorMapper
          include Response

          def call
            yield
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

          def unauthorized
            error_response(401, "unauthorized", "client authentication failed")
          end

          private

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
        end
      end
    end
  end
end
