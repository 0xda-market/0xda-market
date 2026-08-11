# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class ArchitectureBoundariesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CORE_ROOT = File.join(ROOT, "lib/zero_x_da/market/core")
  PROJECT_CONTRACT = File.join(ROOT, "PROJECT_INSTRUCTIONS.yaml")
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
  CONCRETE_CHANNEL_MARKERS = /(?:telegram|telethon|mtproto|fragment|smartglocal)/i
  PROVIDER_PROTOCOL_MARKERS = /(?:telethon|mtproto|core\.telegram\.org|fragment\.com|smartglocal|getPremiumGiftCodeOptions)/i
  FORBIDDEN_RESEARCH_COMPONENTS = %w[research researches].freeze

  def test_core_depends_only_on_its_own_abstractions
    violations = ruby_files(CORE_ROOT).filter_map do |path|
      path if File.read(path).match?(FORBIDDEN_CORE_DEPENDENCIES)
    end

    assert_empty violations, "core imports outward dependencies: #{relative(violations).join(", ")}"
  end

  def test_runtime_boundary_has_no_concrete_provider_names
    violations = RUNTIME_BOUNDARY_FILES.filter_map do |relative_path|
      path = File.join(ROOT, relative_path)
      relative_path if File.read(path).match?(CONCRETE_CHANNEL_MARKERS)
    end

    assert_empty violations, "concrete provider leaked into runtime boundary: #{violations.join(", ")}"
  end

  def test_production_ruby_has_no_concrete_channel_or_payment_provider_logic
    files = ruby_files(File.join(ROOT, "lib")) + [File.join(ROOT, "config.ru")]
    violations = files.filter_map do |path|
      path if File.read(path).match?(CONCRETE_CHANNEL_MARKERS)
    end

    assert_empty violations,
                 "provider-specific logic belongs in an adapter repository: #{relative(violations).join(", ")}"
  end

  def test_repository_has_no_research_or_researches_paths
    violations = repository_paths.select do |relative_path|
      components = relative_path.split(File::SEPARATOR).map(&:downcase)
      (components & FORBIDDEN_RESEARCH_COMPONENTS).any?
    end

    assert_empty violations,
                 "research belongs in 0xda-market/docs, not core: #{violations.join(", ")}"
  end

  def test_core_documentation_has_no_concrete_channel_or_payment_provider_content
    files = [File.join(ROOT, "README.md")] + Dir.glob(File.join(ROOT, "docs", "**", "*.md"))
    violations = files.filter_map do |path|
      path if File.read(path).match?(CONCRETE_CHANNEL_MARKERS)
    end

    assert_empty violations,
                 "provider-specific documentation belongs in 0xda-market/docs or an adapter repository: #{relative(violations).join(", ")}"
  end

  def test_provider_protocol_or_session_tooling_is_absent
    roots = %w[bin lib tools].map { |name| File.join(ROOT, name) }.select { |path| File.exist?(path) }
    files = roots.flat_map do |root|
      Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }
    end
    violations = files.filter_map do |path|
      path if text_file?(path) && File.read(path).match?(PROVIDER_PROTOCOL_MARKERS)
    end

    assert_empty violations,
                 "provider SDK/protocol tooling belongs outside core: #{relative(violations).join(", ")}"
  end

  def test_machine_readable_contract_records_the_same_boundary
    contract = YAML.safe_load_file(PROJECT_CONTRACT)
    boundary = contract.dig("architecture", "core_boundary") || {}

    assert_equal "provider_agnostic", boundary.fetch("principle")
    assert_equal "0xda-market/docs", boundary.fetch("canonical_research_repository")
    assert_equal %w[research researches], boundary.fetch("forbidden_path_components")

    forbidden = boundary.fetch("forbidden")
    %w[
      provider_specific_research
      cross_repository_research
      provider_sdk_or_protocol_clients
      provider_session_or_credential_tooling
      provider_specific_documentation
      channel_webhooks
      channel_credentials
      provider_specific_economic_defaults
    ].each do |rule|
      assert_includes forbidden, rule
    end

    enforcement = boundary.fetch("enforcement")
    assert_equal "test/architecture_boundaries_test.rb", enforcement.fetch("test")
    assert_equal "test", enforcement.fetch("required_ci_job")
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

  def repository_paths
    Dir.glob(File.join(ROOT, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
      relative_path = path.delete_prefix("#{ROOT}/")
      next if relative_path.empty? || relative_path == ".git" || relative_path.start_with?(".git/")

      relative_path
    end
  end

  def text_file?(path)
    File.open(path, "rb") do |file|
      sample = file.read(4096).to_s
      !sample.include?("\x00")
    end
  rescue Errno::ENOENT, Errno::EACCES
    false
  end

  def relative(paths)
    paths.map { |path| path.delete_prefix("#{ROOT}/") }
  end
end
