# frozen_string_literal: true

require "json"
require_relative "../../core/contracts"
require_relative "../../localization/service"

module ZeroXDA
  module Market
    module Transport
      class JSONAPI
        class RequestParser
          MAX_BODY_BYTES = 1_048_576

          def initialize(localization: nil)
            @localization = localization
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
        end
      end
    end
  end
end
