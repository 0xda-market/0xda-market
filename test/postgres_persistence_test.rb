# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/adapters/postgres_store"
require "zero_x_da/market/adapters/postgres_manual_task_store"
require "zero_x_da/market/adapters/postgres_telegram_store"
require "zero_x_da/market/providers/manual_provider"
require "zero_x_da/market/identity/postgres_store"
require "zero_x_da/market/identity/telegram_auth_service"
require "zero_x_da/market/catalog/postgres_store"

class PostgresPersistenceTest < Minitest::Test
  DATABASE_URL = ENV["TEST_DATABASE_URL"]

  def setup
    skip "TEST_DATABASE_URL is not configured" unless DATABASE_URL

    @database = connect
    migrate(@database)
    @database.connection.run(<<~SQL)
      TRUNCATE market.user_identities,
               market.telegram_updates,
               market.telegram_brokers,
               market.telegram_demo_orders,
               market.manual_tasks,
               market.orders,
               market.quotes,
               market.intents CASCADE
    SQL
    @database.connection.run("DELETE FROM market.users")
  end

  def teardown
    @database&.disconnect
  end

  def test_core_records_and_manual_tasks_survive_reconnection
    clock = MutableClock.new
    kernel, provider = build_application(@database, clock, SequenceIDs.new)

    intent = kernel.create_intent(
      capability: "manual.fulfillment",
      payload: { action: "deliver" },
      context: { customer: "customer-1" }
    )
    quote = kernel.quote_intent(intent.id)
    order = kernel.accept_quote(quote.id)
    pending = kernel.execute_order(order.id)
    task_id = pending.progress.fetch("reference")

    @database.disconnect
    @database = connect
    restarted_kernel, restarted_provider = build_application(
      @database,
      clock,
      -> { raise "a persisted lifecycle must not generate another id" }
    )

    assert_equal "pending", restarted_kernel.find_order(order.id).status
    assert_equal order.id, restarted_provider.fetch_task(task_id).order_id

    restarted_provider.complete_task(
      task_id,
      reference: "operator-result-1",
      data: { delivered: true }
    )
    completed = restarted_kernel.execute_order(order.id)

    assert_equal "succeeded", completed.status
    assert_equal "operator-result-1", completed.result.fetch("reference")
    assert completed.result.dig("data", "delivered")
    assert_equal 1, restarted_provider.fetch_task(task_id).version
    assert_equal provider.key, restarted_provider.key
  end

  def test_migrations_are_idempotent
    migrate(@database)

    versions = @database.connection[
      Sequel.qualify(:market, :schema_migrations)
    ].select_map(:version)
    assert_equal(
      %w[
        001_initial 002_telegram_demo 003_users_and_identities
        004_products 005_pricing 006_replace_premium_9m_with_12m
        007_product_catalog_localizations
      ],
      versions
    )
  end

  def test_product_catalog_is_seeded_and_survives_reconnection
    store = ZeroXDA::Market::Catalog::PostgresStore.new(database: @database)

    assert_equal 9, store.list_products(status: "active").length
    premium = store.find_product("premium_12m")
    assert_equal "Telegram Premium 12 months", premium.name
    assert_equal "Premium 12m", premium.short_name
    assert_equal "en_US", premium.locale
    assert_equal 12, premium.metadata.fetch("duration_months")
    assert_nil store.find_product("premium_9m")

    ukrainian = store.find_product("premium_12m", locale: "uk_UA")
    assert_equal "Telegram Premium 12 міс.", ukrainian.name
    assert_equal "Premium 12 міс.", ukrainian.button_label
    assert_equal "uk_UA", ukrainian.locale

    @database.disconnect
    @database = connect
    restarted = ZeroXDA::Market::Catalog::PostgresStore.new(database: @database)

    assert_equal %w[
      premium_3m premium_6m premium_12m
      stars_500 stars_1000 stars_3000
      ton btc eth
    ], restarted.list_products(status: "active").map(&:sku)
  end

  def test_product_price_snapshot_tracks_internal_editor_and_history
    user_id = "00000000-0000-4000-8000-000000000071"
    @database.connection[Sequel.qualify(:market, :users)].insert(
      id: user_id,
      role: "admin",
      status: "active"
    )
    price_id = @database.connection[
      Sequel.qualify(:market, :product_prices)
    ].insert(
      sku: "premium_3m",
      amount_usdt: 12.5,
      source: "admin",
      set_by_user_id: user_id,
      created_at: Time.utc(2026, 7, 19, 12, 0, 0)
    )

    product = @database.connection[
      Sequel.qualify(:market, :products)
    ].where(sku: "premium_3m").first
    assert_equal price_id, product.fetch(:current_price_id)
    assert_equal BigDecimal("12.5"), BigDecimal(product.fetch(:current_price_usdt).to_s)
    assert_equal user_id, product.fetch(:price_updated_by_user_id).to_s
    assert_equal user_id, product.fetch(:updated_by_user_id).to_s
  ensure
    if @database
      @database.connection[Sequel.qualify(:market, :product_prices)]
               .where(sku: "premium_3m")
               .delete
      @database.connection[Sequel.qualify(:market, :products)]
               .where(sku: "premium_3m")
               .update(
                 current_price_id: nil,
                 current_price_usdt: nil,
                 price_updated_at: nil,
                 price_updated_by_user_id: nil,
                 updated_by_user_id: nil
               )
    end
  end

  def test_telegram_identity_survives_reconnection
    clock = MutableClock.new
    identifiers = [
      "00000000-0000-4000-8000-000000000001",
      "00000000-0000-4000-8000-000000000002"
    ].each
    service = build_identity_service(@database, clock, -> { identifiers.next })
    first = service.authenticate(
      provider_user_id: 77,
      provider_data: { chat_id: "77", username: "zero" }
    )

    @database.disconnect
    @database = connect
    restarted = build_identity_service(
      @database,
      clock,
      -> { raise "an existing identity must not generate another id" }
    )
    second = restarted.authenticate(
      provider_user_id: 77,
      provider_data: { chat_id: "770", username: "zero_updated" }
    )

    refute second.created
    assert_equal first.user.id, second.user.id
    assert_equal first.identity.id, second.identity.id
    assert_equal "770", second.identity.provider_data.fetch("chat_id")
  end

  def test_telegram_auth_recovers_from_a_stale_pooled_connection
    clock = MutableClock.new
    identifiers = [
      "00000000-0000-4000-8000-000000000021",
      "00000000-0000-4000-8000-000000000022"
    ].each
    service = build_identity_service(@database, clock, -> { identifiers.next })

    @database.connection.synchronize(&:finish)

    authentication = service.authenticate(
      provider_user_id: 77,
      provider_data: { chat_id: "77", username: "zero" }
    )

    assert authentication.created
    assert_equal "77", authentication.identity.provider_user_id
    assert @database.healthy?
  end

  def test_admin_role_assignment_survives_reconnection
    clock = MutableClock.new
    identifiers = [
      "00000000-0000-4000-8000-000000000011",
      "00000000-0000-4000-8000-000000000012",
      "00000000-0000-4000-8000-000000000013",
      "00000000-0000-4000-8000-000000000014"
    ].each
    service = ZeroXDA::Market::Identity::TelegramAuthService.new(
      store: ZeroXDA::Market::Identity::PostgresStore.new(database: @database),
      clock: clock,
      id_generator: -> { identifiers.next },
      bootstrap_admin_ids: [77]
    )
    service.authenticate(
      provider_user_id: 77,
      provider_data: { chat_id: "77", username: "owner" }
    )
    target = service.authenticate(
      provider_user_id: 78,
      provider_data: { chat_id: "78", username: "target_user" }
    )
    service.set_admin(actor_provider_user_id: 77, target: "@target_user")

    @database.disconnect
    @database = connect
    store = ZeroXDA::Market::Identity::PostgresStore.new(database: @database)

    assert_equal "admin", store.find_user(target.user.id).role
  end

  def test_telegram_broker_and_demo_order_state_survive_reconnection
    clock = MutableClock.new
    kernel, provider = build_application(@database, clock, SequenceIDs.new)
    intent = kernel.create_intent(
      capability: "manual.fulfillment",
      payload: { item: "100 stars" },
      context: { client_chat_id: "201" }
    )
    order = kernel.accept_quote(kernel.quote_intent(intent.id).id)
    pending = kernel.execute_order(order.id)
    task_id = pending.progress.fetch("reference")
    telegram = ZeroXDA::Market::Adapters::PostgresTelegramStore.new(database: @database)
    telegram.register_broker(
      chat_id: "101",
      user_id: "101",
      username: "broker_one",
      display_name: "Broker One",
      at: clock.call
    )
    telegram.insert_demo_order(
      task_id: task_id,
      order_id: order.id,
      client_chat_id: "201",
      at: clock.call
    )
    provider.claim_task(task_id, assignee: "telegram:101")
    telegram.assign_demo_order(
      task_id: task_id,
      broker_chat_id: "101",
      at: clock.call
    )

    @database.disconnect
    @database = connect
    restarted = ZeroXDA::Market::Adapters::PostgresTelegramStore.new(database: @database)
    restarted_kernel, restarted_provider = build_application(
      @database,
      clock,
      -> { raise "persisted Telegram state must not generate another id" }
    )

    assert_equal "ready", restarted.fetch_broker("101").status
    persisted = restarted.fetch_demo_order(task_id)
    assert_equal "awaiting_payment", persisted.status
    assert_equal "101", persisted.broker_chat_id
    assert_equal "telegram:101", restarted_provider.fetch_task(task_id).claimed_by

    paid, = restarted.pay_demo_order(
      task_id: task_id,
      client_chat_id: "201",
      at: clock.call
    )
    restarted_provider.complete_task(
      task_id,
      reference: "telegram:broker:101",
      data: { delivered: true }
    )
    restarted_kernel.execute_order(order.id)
    completed, = restarted.complete_demo_order(
      task_id: task_id,
      broker_chat_id: "101",
      at: clock.call
    )

    assert_equal "processing", paid.status
    assert_equal "completed", completed.status
    assert_equal "succeeded", restarted_kernel.find_order(order.id).status
  end

  private

  def connect
    ZeroXDA::Market::Adapters::PostgresDatabase.new(
      url: DATABASE_URL,
      max_connections: 2
    )
  end

  def migrate(database)
    ZeroXDA::Market::Adapters::PostgresMigrator.new(
      database: database,
      path: File.expand_path("../db/migrations", __dir__)
    ).migrate!
  end

  def build_application(database, clock, id_generator)
    task_store = ZeroXDA::Market::Adapters::PostgresManualTaskStore.new(database: database)
    provider = ZeroXDA::Market::Providers::ManualProvider.new(
      key: "manual.default",
      clock: clock,
      task_store: task_store
    )
    kernel = ZeroXDA::Market::Core::Kernel.new(
      providers: { "manual.fulfillment" => provider },
      store: ZeroXDA::Market::Adapters::PostgresStore.new(database: database),
      clock: clock,
      id_generator: id_generator
    )
    [kernel, provider]
  end

  def build_identity_service(database, clock, id_generator)
    ZeroXDA::Market::Identity::TelegramAuthService.new(
      store: ZeroXDA::Market::Identity::PostgresStore.new(database: database),
      clock: clock,
      id_generator: id_generator
    )
  end
end
