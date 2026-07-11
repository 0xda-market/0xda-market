# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/adapters/postgres_database"
require "zero_x_da/market/adapters/postgres_migrator"
require "zero_x_da/market/adapters/postgres_store"
require "zero_x_da/market/adapters/postgres_manual_task_store"
require "zero_x_da/market/providers/manual_provider"

class PostgresPersistenceTest < Minitest::Test
  DATABASE_URL = ENV["TEST_DATABASE_URL"]

  def setup
    skip "TEST_DATABASE_URL is not configured" unless DATABASE_URL

    @database = connect
    migrate(@database)
    @database.connection.run(<<~SQL)
      TRUNCATE market.manual_tasks, market.orders, market.quotes, market.intents CASCADE
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
    assert_equal ["001_initial"], versions
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
