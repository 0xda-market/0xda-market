# frozen_string_literal: true

require_relative "test_helper"

class ArchitectureBoundariesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CORE_ROOT = File.join(ROOT, "lib/zero_x_da/market/core")
  RUNTIME_BOUNDARY_FILES = %w[
    config.ru
    deploy/vps/.env.example
    lib/zero_x_da/market/identity/service.rb
    lib/zero_x_da/market/identity/admin_service.rb
    lib/zero_x_da/market/transport/json_api.rb
    lib/zero_x_da/market/transport/manual_api.rb
  ].freeze
  FORBIDDEN_CORE_DEPENDENCIES = %r{
    require_relative\s+["']\.\./(?:adapters|identity|providers|telegram|transport)/
  }x

  def test_core_depends_only_on_its_own_abstractions
    violations = ruby_files(CORE_ROOT).filter_map do |path|
      path if File.read(path).match?(FORBIDDEN_CORE_DEPENDENCIES)
    end

    assert_empty violations, "core imports outward dependencies: #{relative(violations).join(", ")}"
  end

  def test_runtime_boundary_has_no_concrete_provider_names
    violations = RUNTIME_BOUNDARY_FILES.filter_map do |relative_path|
      path = File.join(ROOT, relative_path)
      relative_path if File.read(path).match?(/telegram/i)
    end

    assert_empty violations, "concrete provider leaked into runtime boundary: #{violations.join(", ")}"
  end

  def test_legacy_provider_runtime_files_are_absent
    forbidden = %w[
      bin/configure_telegram_webhooks
      lib/zero_x_da/market/adapters/postgres_telegram_store.rb
      lib/zero_x_da/market/identity/telegram_auth_service.rb
      lib/zero_x_da/market/telegram
      lib/zero_x_da/market/transport/telegram_user_identity.rb
    ]
    present = forbidden.select { |relative_path| File.exist?(File.join(ROOT, relative_path)) }

    assert_empty present, "legacy provider runtime files remain: #{present.join(", ")}"
  end

  def test_operator_transport_does_not_import_a_concrete_provider
    source = File.read(File.join(ROOT, "lib/zero_x_da/market/transport/manual_api.rb"))

    refute_match(%r{require_relative\s+["']\.\./providers/}, source)
    assert_includes source, "REQUIRED_TASK_METHODS"
  end

  private

  def ruby_files(root)
    Dir.glob(File.join(root, "**/*.rb")).sort
  end

  def relative(paths)
    paths.map { |path| path.delete_prefix("#{ROOT}/") }
  end
end
