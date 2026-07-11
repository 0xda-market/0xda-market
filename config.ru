# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require_relative "lib/zero_x_da/market/core/kernel"
require_relative "lib/zero_x_da/market/adapters/memory_store"
require_relative "lib/zero_x_da/market/providers/manual_provider"
require_relative "lib/zero_x_da/market/transport/json_api"
require_relative "lib/zero_x_da/market/transport/manual_api"

clock = -> { Time.now.utc }
environment = ENV.fetch("RACK_ENV", "development")
public_token = ENV["PUBLIC_API_TOKEN"]
operator_token = ENV["MANUAL_PROVIDER_TOKEN"]

if environment == "production"
  required_secrets = {
    "PUBLIC_API_TOKEN" => public_token,
    "MANUAL_PROVIDER_TOKEN" => operator_token
  }
  missing = required_secrets.filter_map do |name, value|
    name if value.nil? || value.empty?
  end
  unless missing.empty?
    raise "missing required production secrets: #{missing.join(", ")}"
  end
end

manual_provider = if operator_token && !operator_token.empty?
                    ZeroXDA::Market::Providers::ManualProvider.new(
                      key: "manual.default",
                      clock: clock
                    )
                  end
providers = manual_provider ? { "manual.fulfillment" => manual_provider } : {}

kernel = ZeroXDA::Market::Core::Kernel.new(
  providers: providers,
  store: ZeroXDA::Market::Adapters::MemoryStore.new,
  clock: clock,
  id_generator: SecureRandom.method(:uuid)
)

public_api = ZeroXDA::Market::Transport::JSONAPI.new(
  kernel: kernel,
  token: public_token
)

if manual_provider
  operator_api = ZeroXDA::Market::Transport::ManualAPI.new(
    provider: manual_provider,
    token: operator_token
  )
  run Rack::URLMap.new("/operator" => operator_api, "/" => public_api)
else
  run public_api
end
