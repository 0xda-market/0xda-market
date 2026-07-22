# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "zero_x_da/market/transport/json_api/error_mapper"

class JSONAPIErrorMapperTest < Minitest::Test
  CASES = [
    [JSON::ParserError.new("unexpected token"), 400, "invalid_json", {}],
    [KeyError.new("key not found", key: :payload), 400, "missing_field", { "field" => "payload" }],
    [ZeroXDA::Market::Core::NotFound.new(:intent, "intent-1"), 404, "not_found",
     { "resource" => "intent", "id" => "intent-1" }],
    [ZeroXDA::Market::Core::Forbidden.new, 403, "forbidden", {}],
    [ZeroXDA::Market::Core::UnknownCapability.new("unknown.operation"), 422, "unknown_capability",
     { "capability" => "unknown.operation" }],
    [ArgumentError.new("payload must be an object"), 422, "validation_error", {}],
    [ZeroXDA::Market::Core::Conflict.new("already changed"), 409, "conflict", {}],
    [ZeroXDA::Market::Core::ProviderFailure.new("provider unavailable"), 502, "provider_failure", {}],
    [RuntimeError.new("private failure"), 500, "internal_error", {}]
  ].freeze

  def test_preserves_the_existing_exception_to_http_contract
    mapper = ZeroXDA::Market::Transport::JSONAPI::ErrorMapper.new

    CASES.each do |error, expected_status, expected_code, expected_details|
      status, headers, body = mapper.call { raise error }
      document = JSON.parse(body.join)

      assert_equal expected_status, status, error.class.name
      assert_equal "application/json; charset=utf-8", headers.fetch("content-type")
      assert_equal "no-store", headers.fetch("cache-control")
      assert_equal expected_code, document.dig("errors", 0, "code")
      assert_equal expected_details, document.dig("errors", 0, "details")
    end
  end

  def test_does_not_expose_an_unhandled_exception_message
    mapper = ZeroXDA::Market::Transport::JSONAPI::ErrorMapper.new

    _status, _headers, body = mapper.call { raise "database password leaked" }

    error = JSON.parse(body.join).fetch("errors").first
    assert_equal "the server could not process the request", error.fetch("message")
    refute_includes body.join, "database password leaked"
  end
end
