# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "zero_x_da/market/transport/json_api/request_parser"

class JSONAPIRequestParserTest < Minitest::Test
  class Localization
    def supported_currency?(currency)
      %w[USDT USD].include?(currency)
    end

    def locale_for(value)
      value == "uk" ? "uk_UA" : "en_US"
    end
  end

  def test_parses_json_objects_and_accepts_structured_json_media_types
    parser = build_parser
    request = rack_request(
      "POST",
      "/v1/intents",
      body: JSON.generate(capability: "anything.operation", payload: {}),
      content_type: "application/vnd.api+json"
    )

    document = parser.request_document(request)

    assert_equal "anything.operation", document.fetch("capability")
    assert_equal({}, document.fetch("payload"))
  end

  def test_rejects_non_json_content_types_before_reading_the_document
    parser = build_parser
    request = rack_request("POST", "/v1/intents", body: "{}", content_type: "text/plain")

    error = assert_raises(ArgumentError) { parser.request_document(request) }

    assert_equal "content type must be application/json", error.message
  end

  def test_rejects_documents_larger_than_one_megabyte
    parser = build_parser
    request = rack_request(
      "POST",
      "/v1/intents",
      body: "x" * (ZeroXDA::Market::Transport::JSONAPI::RequestParser::MAX_BODY_BYTES + 1),
      content_type: "application/json"
    )

    error = assert_raises(ArgumentError) { parser.request_document(request) }

    assert_equal "request body is too large", error.message
  end

  def test_empty_optional_bodies_remain_valid
    parser = build_parser
    request = rack_request("POST", "/v1/orders/order-1/execute")

    assert_equal({}, parser.ensure_empty_or_object_body(request))
  end

  def test_currency_and_locale_query_normalization_remain_in_the_parser
    parser = build_parser(localization: Localization.new)
    request = rack_request("GET", "/v1/products?currency=usd&language_code=uk")

    assert_equal "USD", parser.requested_currency(request)
    assert_equal "uk_UA", parser.requested_locale(request)
  end

  def test_defaults_remain_provider_independent_without_localization
    parser = build_parser
    request = rack_request("GET", "/v1/products?currency=usd&locale=uk_UA")

    assert_equal "USDT", parser.requested_currency(request)
    assert_equal "en_US", parser.requested_locale(request)
  end

  def test_unsupported_currency_keeps_the_existing_validation_error
    parser = build_parser(localization: Localization.new)
    request = rack_request("GET", "/v1/products?currency=btc")

    error = assert_raises(ArgumentError) { parser.requested_currency(request) }

    assert_equal "currency is not supported: BTC", error.message
  end

  private

  def build_parser(localization: nil)
    ZeroXDA::Market::Transport::JSONAPI::RequestParser.new(localization: localization)
  end

  def rack_request(method, path, body: nil, content_type: nil)
    options = { method: method }
    options[:input] = body if body
    options["CONTENT_TYPE"] = content_type if content_type
    Rack::Request.new(Rack::MockRequest.env_for(path, options))
  end
end
