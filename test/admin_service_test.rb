# frozen_string_literal: true

require_relative "test_helper"
require "zero_x_da/market/identity/admin_service"
require "zero_x_da/market/identity/memory_store"
require "zero_x_da/market/identity/service"

class AdminServiceTest < Minitest::Test
  def setup
    @clock = MutableClock.new
    @store = ZeroXDA::Market::Identity::MemoryStore.new
    @auth = ZeroXDA::Market::Identity::Service.new(
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
    authentication = authenticate(77)

    result = @service.bootstrap(user_id: authentication.user.id)

    assert result.changed
    assert_equal authentication.user.id, result.user.id
    assert_equal "admin", result.user.role
    assert_equal 1, result.user.version
  end

  def test_bootstrap_is_idempotent
    authentication = authenticate(77)

    first = @service.bootstrap(user_id: authentication.user.id)
    second = @service.bootstrap(user_id: authentication.user.id)

    assert first.changed
    refute second.changed
    assert_equal first.user.id, second.user.id
    assert_equal first.user.version, second.user.version
  end

  def test_assigns_admin_by_internal_user_ids
    actor = authenticate(77)
    target = authenticate(78)
    @service.bootstrap(user_id: actor.user.id)

    assignment = @service.assign_admin(
      actor_user_id: actor.user.id,
      target_user_id: target.user.id
    )

    assert assignment.changed
    assert_equal actor.user.id, assignment.actor.id
    assert_equal target.user.id, assignment.user.id
    assert_equal "admin", assignment.user.role
  end

  def test_non_admin_cannot_assign_admin
    actor = authenticate(77)
    target = authenticate(78)

    error = assert_raises(ZeroXDA::Market::Core::Forbidden) do
      @service.assign_admin(
        actor_user_id: actor.user.id,
        target_user_id: target.user.id
      )
    end

    assert_equal "forbidden", error.code
  end

  def test_requires_an_existing_internal_user
    error = assert_raises(ZeroXDA::Market::Core::NotFound) do
      @service.bootstrap(user_id: "missing-user")
    end

    assert_equal "not_found", error.code
  end

  private

  def authenticate(provider_user_id)
    @auth.authenticate(provider: "telegram", provider_user_id: provider_user_id)
  end
end
