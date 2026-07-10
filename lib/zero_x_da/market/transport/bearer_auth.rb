# frozen_string_literal: true

require "rack"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Transport
      class BearerAuth
        def initialize(token:)
          @token = Core::RecordSupport.identifier(token, field: "bearer token")
        end

        def authorized?(request)
          scheme, candidate = request.get_header("HTTP_AUTHORIZATION").to_s.split(" ", 2)
          return false unless scheme == "Bearer" && candidate
          return false unless candidate.bytesize == @token.bytesize

          Rack::Utils.secure_compare(candidate, @token)
        end
      end
    end
  end
end
