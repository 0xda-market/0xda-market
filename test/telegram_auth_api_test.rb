# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "zero_x_da/market/identity/admin_service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/telegram_auth_service"
require "zero_x_da/market/transport/json_api"

class TelegramAuthAPITest < Minitest::Test
  include KernelFixture

  def setup
    clock = MutableClock.new
    provider = TestProvider.new(clock: clock)
    kernel, = build_kernel(provider: provider, clock: clock)
    store = ZeroXDA::Market::Identity::MemoryStore.new
    @identity_service = ZeroXDA::Market::Identity::TelegramAuthService.new(
      store: store,
      clock: clock,
      id_generator: SequenceIDs.new
    )
    @admin_service = ZeroXDA::Market::Identity::AdminService.new(store: store, clock: clock)
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: kernel,
        token: "client-secret",
        identity_service: @identity_service
      )
    )
  end

  def test_authenticates_a_telegram_client_and_reuses_its_user_id
    first = post_auth(
      telegram_user_id: 77,
      chat_id: 77,
      username: "zero",
      first_name: "Sasha",
      language_code: "uk"
    )
    assert_equal 201, first.status
    first_user = JSON.parse(first.body).fetch("data")
    assert first_user.dig("meta", "created")
    assert_equal "client", first_user.dig("attributes", "role")
    assert_equal "77", first_user.dig("attributes", "identity", "provider_user_id")

    second = post_auth(
      telegram_user_id: "77",
      chat_id: "770",
      username: "zero_updated"
    )
    assert_equal 200, second.status
    second_user = JSON.parse(second.body).fetch("data")
    assert_equal first_user.fetch("id"), second_user.fetch("id")
    refute second_user.dig("meta", "created")
    assert_equal "770", second_user.dig("attributes", "identity", "provider_data", "chat_id")
  end

  def test_requires_the_bot_bearer_token
    response = @client.post(
      "/v1/auth/telegram",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(telegram_user_id: 77, chat_id: 77)
    )

    assert_equal 401, response.status
  end

  def test_requires_chat_id
    response = post_auth(telegram_user_id: 77)

    assert_equal 400, response.status
    assert_equal "chat_id", JSON.parse(response.body).dig("errors", 0, "details", "field")
  end

  def test_lists_active_users_with_telegram_id_uuid_and_role
    first = post_auth(telegram_user_id: 77, chat_id: 77)
    second = post_auth(telegram_user_id: 78, chat_id: 78)

    response = @client.get(
      "/v1/users?status=active",
      "HTTP_AUTHORIZATION" => "Bearer client-secret"
    )

    assert_equal 200, response.status
    document = JSON.parse(response.body)
    assert_equal 2, document.dig("meta", "count")
    assert_equal [first, second].map { |item| JSON.parse(item.body).dig("data", "id") },
                 document.fetch("data").map { |item| item.fetch("id") }
    telegram_ids = document.fetch("data").map do |item|
      item.dig("attributes", "telegram_user_id")
    end
    assert_equal %w[77 78], telegram_ids
    assert document.fetch("data").all? { |item| item.dig("attributes", "role") == "client" }
  end

  def test_active_users_requires_the_bearer_token
    response = @client.get("/v1/users?status=active")

    assert_equal 401, response.status
  end

  def test_admin_promotes_a_user_and_receives_the_target_chat
    owner = post_auth(
      telegram_user_id: 99,
      chat_id: 990,
      username: "owner"
    )
    owner_id = JSON.parse(owner.body).dig("data", "id")
    @admin_service.bootstrap(user_id: owner_id)
    target = post_auth(
      telegram_user_id: 77,
      chat_id: 770,
      username: "target_user"
    )

    response = post_admin(actor_telegram_user_id: 99, target: "@target_user")

    assert_equal 200, response.status
    user = JSON.parse(response.body).fetch("data")
    assert_equal JSON.parse(target.body).dig("data", "id"), user.fetch("id")
    assert_equal "admin", user.dig("attributes", "role")
    assert_equal "77", user.dig("attributes", "telegram_user_id")
    assert_equal "770", user.dig("attributes", "telegram_chat_id")
    assert user.dig("meta", "changed")
  end

  def test_client_cannot_promote_a_user
    post_auth(telegram_user_id: 77, chat_id: 77)
    post_auth(telegram_user_id: 78, chat_id: 78)

    response = post_admin(actor_telegram_user_id: 77, target: "78")

    assert_equal 403, response.status
    assert_equal "forbidden", JSON.parse(response.body).dig("errors", 0, "code")
  end

  private

  def post_auth(body)
    @client.post(
      "/v1/auth/telegram",
      "HTTP_AUTHORIZATION" => "Bearer client-secret",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(body)
    )
  end

  def post_admin(body)
    @client.post(
      "/v1/admin/users/set-admin",
      "HTTP_AUTHORIZATION" => "Bearer client-secret",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(body)
    )
  end
end
