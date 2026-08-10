# frozen_string_literal: true

require "bundler/setup"
require "securerandom"
require_relative "lib/zero_x_da/market/core/kernel"
require_relative "lib/zero_x_da/market/adapters/memory_store"
require_relative "lib/zero_x_da/market/adapters/postgres_database"
require_relative "lib/zero_x_da/market/adapters/postgres_store"
require_relative "lib/zero_x_da/market/adapters/postgres_manual_task_store"
require_relative "lib/zero_x_da/market/providers/manual_provider"
require_relative "lib/zero_x_da/market/payments/mock_provider"
require_relative "lib/zero_x_da/market/payments/rack_confirmation_client"
require_relative "lib/zero_x_da/market/transport/json_api"
require_relative "lib/zero_x_da/market/transport/manual_api"
require_relative "lib/zero_x_da/market/transport/manual_payment_confirmation"
require_relative "lib/zero_x_da/market/transport/mock_payment_api"
require_relative "lib/zero_x_da/market/identity/admin_service"
require_relative "lib/zero_x_da/market/identity/memory_store"
require_relative "lib/zero_x_da/market/identity/postgres_store"
require_relative "lib/zero_x_da/market/identity/service"
require_relative "lib/zero_x_da/market/catalog/memory_store"
require_relative "lib/zero_x_da/market/catalog/postgres_store"
require_relative "lib/zero_x_da/market/catalog/service"
require_relative "lib/zero_x_da/market/pricing/memory_store"
require_relative "lib/zero_x_da/market/pricing/postgres_store"
require_relative "lib/zero_x_da/market/pricing/profitability_policy"
require_relative "lib/zero_x_da/market/pricing/service"
require_relative "lib/zero_x_da/market/localization/service"
require_relative "lib/zero_x_da/market/listings/memory_store"
require_relative "lib/zero_x_da/market/listings/postgres_store"
require_relative "lib/zero_x_da/market/listings/service"
require_relative "lib/zero_x_da/market/listings/broker_order_access"
require_relative "lib/zero_x_da/market/broker_earnings/memory_store"
require_relative "lib/zero_x_da/market/broker_earnings/postgres_store"
require_relative "lib/zero_x_da/market/broker_earnings/service"
require_relative "lib/zero_x_da/market/broker_orders/memory_store"
require_relative "lib/zero_x_da/market/broker_orders/postgres_store"
require_relative "lib/zero_x_da/market/broker_orders/service"
require_relative "lib/zero_x_da/market/marketplace/recipient_resolver"
require_relative "lib/zero_x_da/market/marketplace/service"
require_relative "lib/zero_x_da/market/marketplace/broker_order_decisions"
require_relative "lib/zero_x_da/market/settlement/memory_store"
require_relative "lib/zero_x_da/market/settlement/postgres_store"
require_relative "lib/zero_x_da/market/settlement/manual_provider"
require_relative "lib/zero_x_da/market/settlement/integer_unit_provider"
require_relative "lib/zero_x_da/market/settlement/integration"

clock = -> { Time.now.utc }
environment = ENV.fetch("DEPLOY_ENV", "development")
public_token = ENV["PUBLIC_API_TOKEN"]
operator_token = ENV["MANUAL_PROVIDER_TOKEN"]
database_url = ENV["DATABASE_URL"]
mock_payment_enabled = ENV.fetch("ENABLE_MOCK_PAYMENT_PROVIDER", "0") == "1"
mock_payment_token = ENV["MOCK_PAYMENT_PROVIDER_TOKEN"]
market_payment_provider = ENV["MARKET_PAYMENT_PROVIDER"].to_s.strip
manual_quote_ttl = Integer(ENV.fetch("MANUAL_QUOTE_TTL_SECONDS", "900"))
raise "MANUAL_QUOTE_TTL_SECONDS must be positive" unless manual_quote_ttl.positive?
raise "MARKET_PAYMENT_PROVIDER is unsupported" unless ["", "telegram_stars"].include?(market_payment_provider)
if mock_payment_enabled && !market_payment_provider.empty?
  raise "mock and real market payment providers cannot be enabled together"
end

telegram_stars_rate = nil
telegram_stars_skus = nil
if market_payment_provider == "telegram_stars"
  telegram_stars_rate = ENV["TELEGRAM_STARS_USDT_PER_STAR"].to_s.strip
  raise "TELEGRAM_STARS_USDT_PER_STAR is required for telegram_stars payments" if telegram_stars_rate.empty?

  telegram_stars_skus = ENV.fetch(
    "TELEGRAM_STARS_PAYMENT_SKUS",
    "premium_3m,premium_6m,premium_9m"
  ).split(",").map(&:strip).reject(&:empty?).uniq
  raise "TELEGRAM_STARS_PAYMENT_SKUS must contain at least one SKU" if telegram_stars_skus.empty?
end

if environment == "production"
  raise "mock payment provider cannot be enabled in production" if mock_payment_enabled
  required_secrets = { "PUBLIC_API_TOKEN" => public_token, "MANUAL_PROVIDER_TOKEN" => operator_token,
                       "DATABASE_URL" => database_url }
  missing = required_secrets.filter_map { |name, value| name if value.nil? || value.empty? }
  raise "missing required production secrets: #{missing.join(", ")}" unless missing.empty?
end

if mock_payment_enabled
  required_mock_secrets = { "MANUAL_PROVIDER_TOKEN" => operator_token,
                            "MOCK_PAYMENT_PROVIDER_TOKEN" => mock_payment_token }
  missing = required_mock_secrets.filter_map { |name, value| name if value.nil? || value.empty? }
  raise "missing required mock payment secrets: #{missing.join(", ")}" unless missing.empty?
end

database = if database_url && !database_url.empty?
             ZeroXDA::Market::Adapters::PostgresDatabase.new(url: database_url,
                                                              max_connections: Integer(ENV.fetch("DB_POOL", "5")))
           end
store = database ? ZeroXDA::Market::Adapters::PostgresStore.new(database: database) : ZeroXDA::Market::Adapters::MemoryStore.new
task_store = database && ZeroXDA::Market::Adapters::PostgresManualTaskStore.new(database: database)
identity_store = database ? ZeroXDA::Market::Identity::PostgresStore.new(database: database) : ZeroXDA::Market::Identity::MemoryStore.new
catalog_store = database ? ZeroXDA::Market::Catalog::PostgresStore.new(database: database) : ZeroXDA::Market::Catalog::MemoryStore.new
catalog = ZeroXDA::Market::Catalog::Service.new(store: catalog_store)
pricing_store = database ? ZeroXDA::Market::Pricing::PostgresStore.new(database: database) : ZeroXDA::Market::Pricing::MemoryStore.new
pricing = ZeroXDA::Market::Pricing::Service.new(store: pricing_store, catalog: catalog, clock: clock)
localization = ZeroXDA::Market::Localization::Service.new(catalog: catalog, clock: clock,
                                                          max_rate_age_seconds: Integer(ENV.fetch("FX_RATE_MAX_AGE_SECONDS", "3600")))
manual_provider = if operator_token && !operator_token.empty?
                    ZeroXDA::Market::Providers::ManualProvider.new(key: "manual.default", clock: clock,
                                                                   quote_ttl: manual_quote_ttl,
                                                                   **(task_store ? { task_store: task_store } : {}))
                  end
providers = manual_provider ? { "manual.fulfillment" => manual_provider } : {}
settlement_store = database ? ZeroXDA::Market::Settlement::PostgresStore.new(database: database) : ZeroXDA::Market::Settlement::MemoryStore.new
settlement_options = {
  variable_fee_bps: Integer(ENV.fetch("MARKETPLACE_VARIABLE_FEE_BPS", ZeroXDA::Market::Pricing::ProfitabilityPolicy::DEFAULT_VARIABLE_FEE_BPS.to_s)),
  fixed_cost_usdt: ENV.fetch("MARKETPLACE_FIXED_COST_USDT", ZeroXDA::Market::Pricing::ProfitabilityPolicy::DEFAULT_FIXED_COST_USDT.to_s("F"))
}
manual_settlement_provider = if operator_token && !operator_token.empty? && market_payment_provider.empty?
                               ZeroXDA::Market::Settlement::ManualProvider.new(
                                 clock: clock,
                                 store: settlement_store,
                                 **settlement_options,
                                 tolerance_bps: Integer(ENV.fetch("MANUAL_SETTLEMENT_TOLERANCE_BPS", "0"))
                               )
                             end
settlement_provider = case market_payment_provider
                      when "telegram_stars"
                        ZeroXDA::Market::Settlement::IntegerUnitProvider.new(
                          key: "telegram_stars",
                          currency: "XTR",
                          usdt_per_unit: telegram_stars_rate,
                          allowed_skus: telegram_stars_skus,
                          clock: clock,
                          store: settlement_store,
                          **settlement_options
                        )
                      else
                        manual_settlement_provider
                      end
payment_terms_provider = settlement_provider if market_payment_provider == "telegram_stars"
settlement_cost = settlement_provider&.default_cost || ZeroXDA::Market::Core::Contracts::CostResult.new(variable_fee_bps: 0, fixed_cost_usdt: 0)
profitability = ZeroXDA::Market::Pricing::ProfitabilityPolicy.new(
  minimum_margin_bps: Integer(ENV.fetch("MARKETPLACE_MIN_MARGIN_BPS", ZeroXDA::Market::Pricing::ProfitabilityPolicy::DEFAULT_MINIMUM_MARGIN_BPS.to_s)),
  supply_buffer_bps: Integer(ENV.fetch("MARKETPLACE_SUPPLY_BUFFER_BPS", ZeroXDA::Market::Pricing::ProfitabilityPolicy::DEFAULT_SUPPLY_BUFFER_BPS.to_s)),
  variable_fee_bps: settlement_cost.variable_fee_bps, fixed_cost_usdt: settlement_cost.fixed_cost_usdt)
kernel = ZeroXDA::Market::Core::Kernel.new(providers: providers, settlement: settlement_provider, store: store,
                                            clock: clock, id_generator: SecureRandom.method(:uuid))
identity_service = ZeroXDA::Market::Identity::Service.new(store: identity_store, clock: clock)
admin_service = ZeroXDA::Market::Identity::AdminService.new(store: identity_store, clock: clock)
listings_store = database ? ZeroXDA::Market::Listings::PostgresStore.new(database: database) : ZeroXDA::Market::Listings::MemoryStore.new
listings = ZeroXDA::Market::Listings::Service.new(store: listings_store, users: identity_store, catalog: catalog,
                                                  localization: localization, profitability: profitability, clock: clock)
earnings_store = database ? ZeroXDA::Market::BrokerEarnings::PostgresStore.new(database: database) : ZeroXDA::Market::BrokerEarnings::MemoryStore.new
broker_earnings = ZeroXDA::Market::BrokerEarnings::Service.new(store: earnings_store, localization: localization, clock: clock)
broker_order_store = database ? ZeroXDA::Market::BrokerOrders::PostgresStore.new(database: database) : ZeroXDA::Market::BrokerOrders::MemoryStore.new
broker_orders = manual_provider && ZeroXDA::Market::BrokerOrders::Service.new(store: broker_order_store, kernel: kernel,
                                                                               listings: listings, provider: manual_provider,
                                                                               earnings: broker_earnings, clock: clock)
recipient_resolver = ZeroXDA::Market::Marketplace::RecipientResolver.new(identities: identity_store)
marketplace = ZeroXDA::Market::Marketplace::Service.new(kernel: kernel, catalog: catalog, pricing: pricing, listings: listings,
                                                        broker_orders: broker_orders, settlement_provider: settlement_provider,
                                                        recipient_resolver: recipient_resolver,
                                                        payment_terms_provider: payment_terms_provider)
public_api = ZeroXDA::Market::Transport::JSONAPI.new(kernel: kernel, token: public_token, readiness: -> { store.healthy? },
                                                     identity_service: identity_service, admin_service: admin_service,
                                                     catalog: catalog, pricing: pricing, localization: localization,
                                                     listings: listings, marketplace: marketplace, broker_orders: broker_orders,
                                                     broker_earnings: broker_earnings)
applications = { "/" => public_api }
operator_api = nil
if manual_provider
  operator_api = ZeroXDA::Market::Transport::ManualAPI.new(provider: manual_provider, token: operator_token,
                                                            identity_service: identity_service, catalog: catalog,
                                                            marketplace: marketplace,
                                                            settlement_provider: manual_settlement_provider,
                                                            broker_earnings: broker_earnings)
  applications["/operator"] = operator_api
end
if mock_payment_enabled
  confirmation_client = ZeroXDA::Market::Payments::RackConfirmationClient.new(app: operator_api, token: operator_token)
  mock_payment_provider = ZeroXDA::Market::Payments::MockProvider.new(kernel: kernel, confirmation_client: confirmation_client,
                                                                      clock: clock, id_generator: SecureRandom.method(:uuid))
  applications["/mock-payments"] = ZeroXDA::Market::Transport::MockPaymentAPI.new(provider: mock_payment_provider,
                                                                                   token: mock_payment_token)
end
run Rack::URLMap.new(applications)
