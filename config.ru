# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require_relative "lib/zero_x_da/market/core/kernel"
require_relative "lib/zero_x_da/market/adapters/memory_store"
require_relative "lib/zero_x_da/market/transport/json_api"

providers = {
  # "provider.operation" => Provider.new
}.freeze

kernel = ZeroXDA::Market::Core::Kernel.new(
  providers: providers,
  store: ZeroXDA::Market::Adapters::MemoryStore.new,
  clock: -> { Time.now.utc },
  id_generator: SecureRandom.method(:uuid)
)

run ZeroXDA::Market::Transport::JSONAPI.new(kernel: kernel)

