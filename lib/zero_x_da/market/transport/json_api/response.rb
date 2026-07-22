# frozen_string_literal: true

require "json"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        module Response
          JSON_HEADERS = {
            "content-type" => "application/json; charset=utf-8",
            "cache-control" => "no-store"
          }.freeze

          private

          def resource_response(status, resource)
            json_response(status, { "data" => resource })
          end

          def json_response(status, document)
            [status, JSON_HEADERS, [JSON.generate(document)]]
          end
        end
      end
    end
  end
end
