# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "records"

module ZeroXDA
  module Market
    module Identity
      class AdminService
        Result = Data.define(:user, :changed)
        Assignment = Data.define(:user, :actor, :changed)

        def initialize(store:, clock: -> { Time.now.utc })
          @store = store
          @clock = clock
        end

        # Explicit operational bootstrap by the internal market.users.id.
        # External provider identifiers are intentionally not accepted here.
        def bootstrap(user_id:)
          user_id = normalize_user_id(user_id)

          @store.transaction do |store|
            user = fetch_active_user(store, user_id)
            promote(store, user)
          end
        end

        def require_admin(user_id:)
          user_id = normalize_user_id(user_id)

          @store.transaction do |store|
            user = fetch_active_user(store, user_id)
            ensure_admin!(user)
            user
          end
        end

        def assign_admin(actor_user_id:, target_user_id:)
          actor_user_id = normalize_user_id(actor_user_id)
          target_user_id = normalize_user_id(target_user_id)

          @store.transaction do |store|
            actor = fetch_active_user(store, actor_user_id)
            ensure_admin!(actor)
            target = fetch_active_user(store, target_user_id)
            result = promote(store, target)
            Assignment.new(user: result.user, actor: actor, changed: result.changed)
          end
        end

        private

        def normalize_user_id(value)
          Core::RecordSupport.identifier(value.to_s, field: "user id")
        end

        def fetch_active_user(store, user_id)
          user = store.find_user(user_id) || raise(Core::NotFound.new("user", user_id))
          if user.status != "active"
            raise Core::Conflict.new(
              "user is not active",
              code: "user_not_active",
              details: { user_id: user.id }
            )
          end
          user
        end

        def ensure_admin!(user)
          return user if user.role == "admin"

          raise Core::Forbidden.new(
            "admin role is required",
            details: { user_id: user.id }
          )
        end

        def promote(store, user)
          return Result.new(user: user, changed: false) if user.role == "admin"

          replacement = User.new(
            id: user.id,
            role: "admin",
            status: user.status,
            created_at: user.created_at,
            updated_at: current_time,
            version: user.version + 1
          )
          replacement = store.replace_user(replacement, expected_version: user.version)
          Result.new(user: replacement, changed: true)
        end

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
