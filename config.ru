# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require_relative "lib/zero_x_da/market/core/kernel"
require_relative "lib/zero_x_da/market/adapters/memory_store"
require_relative "lib/zero_x_da/market/adapters/postgres_database"
require_relative "lib/zero_x_da/market/adapters/postgres_store"
require_relative "lib/zero_x_da/market/adapters/postgres_manual_task_store"
require_relative "lib/zero_x_da/market/adapters/postgres_telegram_store"
require_relative "lib/zero_x_da/market/providers/manual_provider"
require_relative "lib/zero_x_da/market/transport/json_api"
require_relative "lib/zero_x_da/market/transport/manual_api"
require_relative "lib/zero_x_da/market/telegram/bot_api"
require_relative "lib/zero_x_da/market/telegram/broker_bot"
require_relative "lib/zero_x_da/market/telegram/client_bot"
require_relative "lib/zero_x_da/market/telegram/configuration"
require_relative "lib/zero_x_da/market/telegram/demo_flow"
require_relative "lib/zero_x_da/market/telegram/memory_store"
require_relative "lib/zero_x_da/market/telegram/webhook"

clock = -> { Time.now.utc }
environment = ENV.fetch("RACK_ENV", "development")
public_token = ENV["PUBLIC_API_TOKEN"]
operator_token = ENV["MANUAL_PROVIDER_TOKEN"]
database_url = ENV["DATABASE_URL"]
telegram_configuration = ZeroXDA::Market::Telegram::Configuration.from_env(ENV)

if environment == "production"
  required_secrets = {
    "PUBLIC_API_TOKEN" => public_token,
    "MANUAL_PROVIDER_TOKEN" => operator_token,
    "DATABASE_URL" => database_url,
    "TELEGRAM_CLIENT_BOT_TOKEN" => ENV["TELEGRAM_CLIENT_BOT_TOKEN"],
    "TELEGRAM_BROKER_BOT_TOKEN" => ENV["TELEGRAM_BROKER_BOT_TOKEN"],
    "TELEGRAM_WEBHOOK_BASE_URL" => ENV["TELEGRAM_WEBHOOK_BASE_URL"]
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

public_api = ZeroXDA::Market::Transport::JSONAPI.new(
  kernel: kernel,
  token: public_token,
  readiness: -> { store.healthy? }
)

applications = { "/" => public_api }

if manual_provider
  operator_api = ZeroXDA::Market::Transport::ManualAPI.new(
    provider: manual_provider,
    token: operator_token
  )
  applications["/operator"] = operator_api
end

if telegram_configuration
  raise "Telegram bots require MANUAL_PROVIDER_TOKEN" unless manual_provider

  telegram_store = if database
                     ZeroXDA::Market::Adapters::PostgresTelegramStore.new(database: database)
                   else
                     ZeroXDA::Market::Telegram::MemoryStore.new
                   end
  client_bot_api = ZeroXDA::Market::Telegram::BotAPI.new(
    token: telegram_configuration.client_token
  )
  broker_bot_api = ZeroXDA::Market::Telegram::BotAPI.new(
    token: telegram_configuration.broker_token
  )
  telegram_flow = ZeroXDA::Market::Telegram::DemoFlow.new(
    kernel: kernel,
    provider: manual_provider,
    store: telegram_store,
    client_api: client_bot_api,
    broker_api: broker_bot_api,
    clock: clock
  )
  client_bot = ZeroXDA::Market::Telegram::ClientBot.new(
    flow: telegram_flow,
    api: client_bot_api
  )
  broker_bot = ZeroXDA::Market::Telegram::BrokerBot.new(
    flow: telegram_flow,
    api: broker_bot_api
  )
  applications["/telegram/client"] = ZeroXDA::Market::Telegram::Webhook.new(
    role: "client",
    secret_token: telegram_configuration.secret_token("client"),
    handler: client_bot,
    store: telegram_store,
    clock: clock
  )
  applications["/telegram/broker"] = ZeroXDA::Market::Telegram::Webhook.new(
    role: "broker",
    secret_token: telegram_configuration.secret_token("broker"),
    handler: broker_bot,
    store: telegram_store,
    clock: clock
  )
end

run Rack::URLMap.new(applications)
