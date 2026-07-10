# frozen_string_literal: true

require_relative "test_helper"

class MemoryStoreTest < Minitest::Test
  Core = ZeroXDA::Market::Core

  def setup
    @store = ZeroXDA::Market::Adapters::MemoryStore.new
    @now = Time.utc(2026, 7, 10, 12, 0, 0)
    @intent = Core::Intent.new(
      id: "intent-1",
      capability: "provider.operation",
      payload: {},
      created_at: @now
    )
  end

  def test_inserts_and_fetches_records
    @store.insert(:intents, @intent)

    assert_same @intent, @store.fetch(:intents, @intent.id)
    assert_nil @store.find(:intents, "missing")
  end

  def test_compare_and_swap_rejects_a_stale_version
    @store.insert(:intents, @intent)
    newer = Core::Intent.new(
      id: @intent.id,
      capability: @intent.capability,
      payload: @intent.payload,
      created_at: @intent.created_at,
      version: 1
    )
    @store.replace(:intents, newer, expected_version: 0)

    assert_raises(Core::ConcurrencyConflict) do
      @store.replace(:intents, @intent, expected_version: 0)
    end
  end

  def test_transaction_rolls_back_all_changes_on_failure
    assert_raises(RuntimeError) do
      @store.transaction do |store|
        store.insert(:intents, @intent)
        raise "rollback"
      end
    end

    assert_nil @store.find(:intents, @intent.id)
  end
end

