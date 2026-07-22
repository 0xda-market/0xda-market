# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require_relative "lib/zero_x_da/market/core/kernel"
require_relative "lib/zero_x_da/market/adapters/memory_store"
require_relative "lib/zero_x_da/market/adapters/postgres_database"
require_relative "lib/zero_x_da/market/adapters/postgres_store"
require_relative "lib/zero_x_da/market/adapters/postgres_manual_task_store"
require_relative "lib/zero_x_da/market/providers/manual_provider"
require_relative "lib/zero_x_da/market/transport/json_api"
require_relative "lib/zero_x_da/market/transport/manual_api"
require_relative "lib/zero_x_da/market/identity/admin_service"
require_relative "lib/zero_x_da/market/identity/memory_store"
require_relative "lib/zero_x_da/market/identity/postgres_store"
require_relative "lib/zero_x_da/market/identity/service"
require_relative "lib/zero_x_da/market/catalog/memory_store"
require_relative "lib/zero_x_da/market/catalog/postgres_store"
require_relative "lib/zero_x_da/market/catalog/service"
require_relative "lib/zero_x_da/market/pricing/memory_store"
require_relative "lib/zero_x_da/market/pricing/postgres_store"
require_relative "lib/zero_x_da/market/pricing/service"
require_relative "lib/zero_x_da/market/localization/service"

clock = -> { Time.now.utc }
environment = ENV.fetch("DEPLOY_ENV", "development")
public_token = ENV["PUBLIC_API_TOKEN"]
operator_token = ENV["MANUAL_PROVIDER_TOKEN"]
database_url = ENV["DATABASE_URL"]

if environment == "production"
  required_secrets = {
    "PUBLIC_API_TOKEN" => public_token,
    "MANUAL_PROVIDER_TOKEN" => operator_token,
    "DATABASE_URL" => database_url
  }
  missing = required_secrets.filter_map do |name, value|
    name if value.nil? || value.empty?
  end
  unless missing.empty?
    raise "missing required production secrets: #{missing.join(", ")}"
  end
end

database = if database_url && !database_url.empty?
             ZeroXDA::Market::Adapters::PostgresDatabase.new(
               url: database_url,
               max_connections: Integer(ENV.fetch("DB_POOL", "5"))
             )
           end
store = database ? ZeroXDA::Market::Adapters::PostgresStore.new(database: database) :
                   ZeroXDA::Market::Adapters::MemoryStore.new
task_store = if database
               ZeroXDA::Market::Adapters::PostgresManualTaskStore.new(database: database)
             end
identity_store = if database
                   ZeroXDA::Market::Identity::PostgresStore.new(database: database)
                 else
                   ZeroXDA::Market::Identity::MemoryStore.new
                 end
catalog_store = if database
                  ZeroXDA::Market::Catalog::PostgresStore.new(database: database)
                else
                  ZeroXDA::Market::Catalog::MemoryStore.new
                end
catalog = ZeroXDA::Market::Catalog::Service.new(store: catalog_store)

pricing_store = if database
                  ZeroXDA::Market::Pricing::PostgresStore.new(database: database)
                else
                  ZeroXDA::Market::Pricing::MemoryStore.new
                end
pricing = ZeroXDA::Market::Pricing::Service.new(
  store: pricing_store,
  catalog: catalog,
  clock: clock
)

# Currencies are catalog products; their prices are the exchange rates.
localization = ZeroXDA::Market::Localization::Service.new(catalog: catalog)

manual_provider = if operator_token && !operator_token.empty?
                    ZeroXDA::Market::Providers::ManualProvider.new(
                      key: "manual.default",
                      clock: clock,
                      **(task_store ? { task_store: task_store } : {})
                    )
                  end
providers = manual_provider ? { "manual.fulfillment" => manual_provider } : {}

kernel = ZeroXDA::Market::Core::Kernel.new(
  providers: providers,
  store: store,
  clock: clock,
  id_generator: SecureRandom.method(:uuid)
)

identity_service = ZeroXDA::Market::Identity::Service.new(
  store: identity_store,
  clock: clock
)
admin_service = ZeroXDA::Market::Identity::AdminService.new(
  store: identity_store,
  clock: clock
)
public_api = ZeroXDA::Market::Transport::JSONAPI.new(
  kernel: kernel,
  token: public_token,
  readiness: -> { store.healthy? },
  identity_service: identity_service,
  admin_service: admin_service,
  catalog: catalog,
  pricing: pricing,
  localization: localization
)

applications = { "/" => public_api }

if manual_provider
  operator_api = ZeroXDA::Market::Transport::ManualAPI.new(
    provider: manual_provider,
    token: operator_token,
    identity_service: identity_service,
    catalog: catalog
  )
  applications["/operator"] = operator_api
end

run Rack::URLMap.new(applications)
