# frozen_string_literal: true

require_relative "../core/contracts"
require_relative "records"

module ZeroXDA
  module Market
    module Identity
      class AdminService
        Result = Data.define(:user, :changed)

        def initialize(store:, clock: -> { Time.now.utc })
          @store = store
          @clock = clock
        end

        # Explicit operational bootstrap by the internal market.users.id.
        # External provider identifiers are intentionally not accepted here.
        def bootstrap(user_id:)
          user_id = Core::RecordSupport.identifier(user_id, field: "user id")

          @store.transaction do |store|
            user = store.find_user(user_id) || raise(Core::NotFound.new("user", user_id))
            if user.status != "active"
              raise Core::Conflict.new(
                "user is not active",
                code: "user_not_active",
                details: { user_id: user.id }
              )
            end

            if user.role == "admin"
              Result.new(user: user, changed: false)
            else
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
          end
        end

        private

        def current_time
          value = @clock.call
          raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

          value.getutc
        end
      end
    end
  end
end
