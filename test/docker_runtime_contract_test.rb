# frozen_string_literal: true

require_relative "test_helper"

class DockerRuntimeContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_dockerfile_references_only_existing_runtime_scripts
    dockerfile = File.read(File.join(ROOT, "Dockerfile"))
    scripts = dockerfile.scan(%r{\bbin/[a-zA-Z0-9_./-]+}).uniq

    refute_empty scripts
    scripts.each do |script|
      assert File.file?(File.join(ROOT, script)), "Dockerfile references missing runtime script #{script}"
    end
  end
end
