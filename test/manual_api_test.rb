# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "zero_x_da/market/providers/manual_provider"
require "zero_x_da/market/transport/manual_api"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/telegram_auth_service"
require "zero_x_da/market/catalog/memory_store"
require "zero_x_da/market/catalog/product"
require "zero_x_da/market/catalog/service"

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
    product = ZeroXDA::Market::Catalog::Product.new(
      sku: "ton",
      name: "TON",
      button_label: "TON",
      metadata: { symbol: "TON" },
      position: 1,
      created_at: @clock.call
    )
    catalog = ZeroXDA::Market::Catalog::Service.new(
      store: ZeroXDA::Market::Catalog::MemoryStore.new(products: [product])
    )
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::ManualAPI.new(
        provider: @provider,
        token: "operator-secret",
        identity_service: ZeroXDA::Market::Identity::TelegramAuthService.new(
          store: ZeroXDA::Market::Identity::MemoryStore.new,
          clock: @clock,
          id_generator: SequenceIDs.new
        ),
        catalog: catalog
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

  def test_lists_products_for_the_operator
    response = authorized_get("/v1/products")

    assert_equal 200, response.status
    document = JSON.parse(response.body)
    assert_equal 1, document.dig("meta", "count")
    assert_equal "ton", document.dig("data", 0, "id")
    assert_equal "TON", document.dig("data", 0, "attributes", "button_label")
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

  def test_authenticates_a_telegram_broker
    response = authorized_post(
      "/v1/auth/telegram",
      telegram_user_id: 77,
      chat_id: 770,
      username: "zero"
    )

    assert_equal 201, response.status
    resource = JSON.parse(response.body).fetch("data")
    assert_equal "broker", resource.dig("attributes", "role")
    assert_equal "77", resource.dig("attributes", "identity", "provider_user_id")
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
