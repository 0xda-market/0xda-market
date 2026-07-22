# frozen_string_literal: true

require_relative "bearer_auth"
require_relative "json_api/endpoint_handler"
require_relative "json_api/error_mapper"
require_relative "json_api/request_parser"
require_relative "json_api/router"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        def initialize(
          kernel:,
          token: nil,
          readiness: -> { true },
          identity_service: nil,
          admin_service: nil,
          catalog: nil,
          pricing: nil,
          localization: nil
        )
          error_mapper = ErrorMapper.new
          request_parser = RequestParser.new(localization: localization)
          endpoint_handler = EndpointHandler.new(
            kernel: kernel,
            readiness: readiness,
            request_parser: request_parser,
            identity_service: identity_service,
            admin_service: admin_service,
            catalog: catalog,
            pricing: pricing,
            localization: localization
          )
          authentication = token && BearerAuth.new(token: token)
          @router = Router.new(
            authentication: authentication,
            error_mapper: error_mapper,
            endpoint_handler: endpoint_handler
          )
        end

        def call(environment)
          @router.call(environment)
        end
      end
    end
  end
end
