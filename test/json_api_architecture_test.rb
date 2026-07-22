# frozen_string_literal: true

require_relative "test_helper"

class JSONAPIArchitectureTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  JSON_API = File.join(ROOT, "lib/zero_x_da/market/transport/json_api.rb")
  COMPONENTS = %w[
    endpoint_handler.rb
    error_mapper.rb
    request_parser.rb
    response.rb
    router.rb
  ].freeze

  def test_json_api_is_only_the_composition_and_delegation_boundary
    source = File.read(JSON_API)

    assert_operator source.lines.length, :<, 60
    assert_includes source, "Router.new"
    assert_includes source, "@router.call(environment)"
    refute_match(/JSON\.parse/, source)
    refute_match(/def route/, source)
    refute_match(/@kernel\./, source)
    refute_match(/@identity_service/, source)
    refute_match(/@catalog/, source)
    refute_match(/@pricing/, source)
  end

  def test_boundary_components_are_explicit_files
    COMPONENTS.each do |name|
      path = File.join(ROOT, "lib/zero_x_da/market/transport/json_api", name)
      assert File.file?(path), "missing #{path}"
    end
  end
end
