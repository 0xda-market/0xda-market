# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "zero_x_da/market/providers/manual_provider"
require "zero_x_da/market/transport/manual_api"

class ManualAPITest < Minitest::Test
  include KernelFixture

  def setup
    @clock = MutableClock.new
    @provider = ZeroXDA::Market::Providers::ManualProvider.new(
      key: "manual.test",
      clock: @clock
    )
    @kernel, = build_kernel(
      provider: @provider,
      clock: @clock,
      capability: "manual.fulfillment"
    )
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::ManualAPI.new(
        provider: @provider,
        token: "operator-secret"
      )
    )
  end

  def test_requires_a_bearer_token
    response = @client.get("/v1/tasks")

    assert_equal 401, response.status
    assert_equal "unauthorized", JSON.parse(response.body).dig("errors", 0, "code")
  end

  def test_lists_and_completes_pending_tasks
    order = accepted_order
    pending = @kernel.execute_order(order.id)

    list = authorized_get("/v1/tasks?status=pending")
    assert_equal 200, list.status
    task = JSON.parse(list.body).fetch("data").fetch(0)
    assert_equal pending.progress.fetch("reference"), task.fetch("id")
    assert_equal "pending", task.dig("attributes", "status")

    completion = authorized_post(
      "/v1/tasks/#{task.fetch("id")}/complete",
      reference: "external-1",
      data: { delivered: true }
    )
    assert_equal 200, completion.status
    assert_equal "completed", JSON.parse(completion.body).dig("data", "attributes", "status")

    completed = @kernel.execute_order(order.id)
    assert_equal "succeeded", completed.status
    assert completed.result.dig("data", "delivered")
  end

  def test_rejects_a_task_with_a_structured_failure
    order = accepted_order
    pending = @kernel.execute_order(order.id)

    response = authorized_post(
      "/v1/tasks/#{pending.progress.fetch("reference")}/reject",
      message: "cannot fulfill",
      code: "out_of_scope",
      details: { category: "unsupported" }
    )

    assert_equal 200, response.status
    assert_equal "rejected", JSON.parse(response.body).dig("data", "attributes", "status")
    error = assert_raises(ZeroXDA::Market::Core::ProviderFailure) do
      @kernel.execute_order(order.id)
    end
    assert_equal "out_of_scope", error.code
  end

  def test_claims_a_pending_task
    order = accepted_order
    pending = @kernel.execute_order(order.id)

    response = authorized_post(
      "/v1/tasks/#{pending.progress.fetch("reference")}/claim",
      assignee: "broker-1"
    )

    assert_equal 200, response.status
    attributes = JSON.parse(response.body).dig("data", "attributes")
    assert_equal "claimed", attributes.fetch("status")
    assert_equal "broker-1", attributes.fetch("claimed_by")
  end

  private

  def accepted_order
    intent = @kernel.create_intent(
      capability: "manual.fulfillment",
      payload: { action: "deliver" }
    )
    @kernel.accept_quote(@kernel.quote_intent(intent.id).id)
  end

  def authorized_get(path)
    @client.get(path, "HTTP_AUTHORIZATION" => "Bearer operator-secret")
  end

  def authorized_post(path, body)
    @client.post(
      path,
      "HTTP_AUTHORIZATION" => "Bearer operator-secret",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(body)
    )
  end
end
