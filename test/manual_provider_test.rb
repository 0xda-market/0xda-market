# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/providers/manual_provider"

class ManualProviderTest < Minitest::Test
  include KernelFixture

  def setup
    @clock = MutableClock.new
    @provider = ZeroXDA::Market::Providers::ManualProvider.new(
      key: "manual.test",
      clock: @clock,
      quote_terms: { fulfillment: "manual", currency: "none" }
    )
    @kernel, = build_kernel(
      provider: @provider,
      clock: @clock,
      capability: "manual.fulfillment"
    )
  end

  def test_completes_an_order_through_an_operator_task
    intent = @kernel.create_intent(
      capability: "manual.fulfillment",
      payload: { action: "deliver", item: "opaque" },
      context: { customer: "customer-1" }
    )
    quote = @kernel.quote_intent(intent.id)
    order = @kernel.accept_quote(quote.id)

    pending = @kernel.execute_order(order.id)
    task = @provider.tasks(status: "pending").fetch(0)

    assert_equal "pending", pending.status
    assert_equal task.id, pending.progress.fetch("reference")
    assert_equal order.id, task.order_id
    assert_equal "deliver", task.payload.fetch("action")

    @provider.complete_task(
      task.id,
      reference: "operator-result-1",
      data: { delivered: true }
    )
    completed = @kernel.execute_order(order.id)

    assert_equal "succeeded", completed.status
    assert_equal "operator-result-1", completed.result.fetch("reference")
    assert completed.result.dig("data", "delivered")
    assert_equal 1, completed.attempts
    assert_equal 1, @provider.fetch_task(task.id).version
  end

  def test_reuses_one_task_for_repeated_provider_execution
    order = accepted_order

    first = @provider.execute(order: order, idempotency_key: "same-key")
    second = @provider.execute(order: order, idempotency_key: "same-key")

    assert_equal first.reference, second.reference
    assert_equal 1, @provider.tasks.length
  end

  def test_claims_a_task_once_and_keeps_the_same_assignee_idempotent
    order = accepted_order
    pending = @provider.execute(order: order, idempotency_key: "claim-key")

    claimed = @provider.claim_task(pending.reference, assignee: "broker-1")
    repeated = @provider.claim_task(pending.reference, assignee: "broker-1")

    assert_equal "claimed", claimed.status
    assert_equal "broker-1", claimed.claimed_by
    assert_equal claimed.version, repeated.version

    error = assert_raises(ZeroXDA::Market::Core::Conflict) do
      @provider.claim_task(pending.reference, assignee: "broker-2")
    end
    assert_equal "task_already_claimed", error.code
  end

  def test_completes_a_claimed_task
    order = accepted_order
    pending = @provider.execute(order: order, idempotency_key: "claimed-completion")
    @provider.claim_task(pending.reference, assignee: "broker-1")

    completed = @provider.complete_task(
      pending.reference,
      reference: "telegram-result",
      data: { delivered: true }
    )

    assert_equal "completed", completed.status
    assert_equal "broker-1", completed.claimed_by
  end

  def test_rejection_becomes_a_non_retryable_provider_failure
    order = accepted_order
    pending = @provider.execute(order: order, idempotency_key: "reject-key")
    @provider.reject_task(
      pending.reference,
      message: "operator rejected the task",
      details: { reason: "unsupported" }
    )

    error = assert_raises(ZeroXDA::Market::Core::ProviderFailure) do
      @provider.execute(order: order, idempotency_key: "reject-key")
    end

    refute error.retryable
    assert_equal "manual_rejection", error.code
    assert_equal "unsupported", error.details.fetch("reason")
  end

  private

  def accepted_order
    intent = @kernel.create_intent(
      capability: "manual.fulfillment",
      payload: {}
    )
    @kernel.accept_quote(@kernel.quote_intent(intent.id).id)
  end
end
