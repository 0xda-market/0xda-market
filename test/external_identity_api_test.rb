# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"
require "zero_x_da/market/identity/admin_service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"
require "zero_x_da/market/transport/json_api"

class ExternalIdentityAPITest < Minitest::Test
  include KernelFixture

  def setup
    clock = MutableClock.new
    provider = TestProvider.new(clock: clock)
    kernel, = build_kernel(provider: provider, clock: clock)
    store = ZeroXDA::Market::Identity::MemoryStore.new
    @identity_service = ZeroXDA::Market::Identity::Service.new(
      store: store,
      clock: clock,
      id_generator: SequenceIDs.new
    )
    @admin_service = ZeroXDA::Market::Identity::AdminService.new(store: store, clock: clock)
    @client = Rack::MockRequest.new(
      ZeroXDA::Market::Transport::JSONAPI.new(
        kernel: kernel,
        token: "client-secret",
        identity_service: @identity_service,
        admin_service: @admin_service
      )
    )
  end

  def test_authenticates_any_external_provider_and_reuses_internal_user_id
    first = post_auth(
      provider: "telegram",
      provider_user_id: 77,
      provider_data: {
        chat_id: "77",
        username: "zero",
        language_code: "uk"
      }
    )
    assert_equal 201, first.status
    first_user = JSON.parse(first.body).fetch("data")
    assert first_user.dig("meta", "created")
    assert_equal "client", first_user.dig("attributes", "role")
    assert_equal "telegram", first_user.dig("attributes", "identity", "provider")
    assert_equal "77", first_user.dig("attributes", "identity", "provider_user_id")

    second = post_auth(
      provider: "telegram",
      provider_user_id: "77",
      provider_data: { chat_id: "770", username: "zero_updated" }
    )
    assert_equal 200, second.status
    second_user = JSON.parse(second.body).fetch("data")
    assert_equal first_user.fetch("id"), second_user.fetch("id")
    refute second_user.dig("meta", "created")
    assert_equal "770", second_user.dig("attributes", "identity", "provider_data", "chat_id")
  end

  def test_requires_the_bot_bearer_token
    response = @client.post(
      "/v1/auth/external",
      "CONTENT_TYPE" => "application/json",
      input: JSON.generate(provider: "telegram", provider_user_id: 77)
    )

    assert_equal 401, response.status
  end

  def test_requires_provider_and_provider_user_id
    response = post_auth(provider: "telegram")

    assert_equal 400, response.status
    assert_equal "provider_user_id", JSON.parse(response.body).dig("errors", 0, "details", "field")
  end

  def test_lists_active_users_with_provider_neutral_identities
    first = post_auth(provider: "telegram", provider_user_id: 77)
    second = post_auth(provider: "github", provider_user_id: "75973992")

    response = @client.get(
      "/v1/users?status=active",
      "HTTP_AUTHORIZATION" => "Bearer client-secret"
    )

    assert_equal 200, response.status
    document = JSON.parse(response.body)
    assert_equal 2, document.dig("meta", "count")
    assert_equal [first, second].map { |item| JSON.parse(item.body).dig("data", "id") },
                 document.fetch("data").map { |item| item.fetch("id") }
    providers = document.fetch("data").map do |item|
      item.dig("attributes", "identities", 0, "provider")
    end
    assert_equal %w[telegram github], providers
  end

  def test_admin_promotes_a_user_by_internal_ids
    owner = JSON.parse(post_auth(provider: "telegram", provider_user_id: 99).body).fetch("data")
    target = JSON.parse(post_auth(provider: "telegram", provider_user_id: 77).body).fetch("data")
    @admin_service.bootstrap(user_id: owner.fetch("id"))

    response = post_admin(
      actor_user_id: owner.fetch("id"),
      target_user_id: target.fetch("id")
    )

    assert_equal 200, response.status
    user = JSON.parse(response.body).fetch("data")
    assert_equal target.fetch("id"), user.fetch("id")
    assert_equal "admin", user.dig("attributes", "role")
    assert user.dig("meta", "changed")
    assert_equal owner.fetch("id"), user.dig("meta", "assigned_by")
  end

  def test_client_cannot_promote_a_user
    actor = JSON.parse(post_auth(provider: "telegram", provider_user_id: 77).body).fetch("data")
    target = JSON.parse(post_auth(provider: "telegram", provider_user_id: 78).body).fetch("data")

    response = post_admin(
      actor_user_id: actor.fetch("id"),
      target_user_id: target.fetch("id")
    )

    assert_equal 403, response.status
    assert_equal "forbidden", JSON.parse(response.body).dig("errors", 0, "code")
  end

  private

  def post_auth(body)
    @client.post(
      "/v1/auth/external",
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
