# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/adapters/postgres_store"
require "zero_x_da/market/adapters/postgres_manual_task_store"
require "zero_x_da/market/adapters/postgres_telegram_store"
require "zero_x_da/market/providers/manual_provider"

class PostgresPersistenceTest < Minitest::Test
  DATABASE_URL = ENV["TEST_DATABASE_URL"]

  def setup
    skip "TEST_DATABASE_URL is not configured" unless DATABASE_URL

    @database = connect
    migrate(@database)
    @database.connection.run(<<~SQL)
      TRUNCATE market.telegram_updates,
               market.telegram_brokers,
               market.telegram_demo_orders,
               market.manual_tasks,
               market.orders,
               market.quotes,
               market.intents CASCADE
    SQL
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
    assert_equal %w[001_initial 002_telegram_demo], versions
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
end
