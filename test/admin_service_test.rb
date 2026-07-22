# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/identity/admin_service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/telegram_auth_service"

class AdminServiceTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    @store = ZeroXDA::Market::Identity::MemoryStore.new
    @auth = ZeroXDA::Market::Identity::TelegramAuthService.new(
      store: @store,
      clock: @clock,
      id_generator: SequenceIDs.new
    )
    @service = ZeroXDA::Market::Identity::AdminService.new(
      store: @store,
      clock: @clock
    )
  end

  def test_bootstraps_an_existing_user_by_internal_id
    authentication = @auth.authenticate(
      provider_user_id: 77,
      provider_data: { chat_id: "77", username: "owner" }
    )

    result = @service.bootstrap(user_id: authentication.user.id)

    assert result.changed
    assert_equal authentication.user.id, result.user.id
    assert_equal "admin", result.user.role
    assert_equal 1, result.user.version
  end

  def test_bootstrap_is_idempotent
    authentication = @auth.authenticate(provider_user_id: 77)

    first = @service.bootstrap(user_id: authentication.user.id)
    second = @service.bootstrap(user_id: authentication.user.id)

    assert first.changed
    refute second.changed
    assert_equal first.user.id, second.user.id
    assert_equal first.user.version, second.user.version
    assert_equal "admin", second.user.role
  end

  def test_bootstrap_does_not_accept_an_external_provider_identifier
    error = assert_raises(ZeroXDA::Market::Core::NotFound) do
      @service.bootstrap(user_id: "77")
    end

    assert_equal "not_found", error.code
  end

  def test_bootstrap_requires_an_existing_internal_user
    error = assert_raises(ZeroXDA::Market::Core::NotFound) do
      @service.bootstrap(user_id: "missing-user")
    end

    assert_equal "not_found", error.code
  end
end
