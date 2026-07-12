# frozen_string_literal: true

require "securerandom"
require_relative "../core/contracts"
require_relative "records"

module ZeroXDA
  module Market
    module Identity
      class TelegramAuthService
        PROVIDER = "telegram"
        TELEGRAM_ID_PATTERN = /\A[1-9][0-9]*\z/

        def initialize(store:, clock: -> { Time.now.utc }, id_generator: SecureRandom.method(:uuid))
          @store = store
          @clock = clock
          @id_generator = id_generator
        end

        def authenticate(provider_user_id:, provider_data: {})
          provider_user_id = normalize_telegram_id(provider_user_id)
          provider_data = Core::RecordSupport.document(provider_data, field: "provider data")
          attempts = 0

          begin
            authenticate_once(provider_user_id, provider_data)
          rescue Core::Conflict => error
            raise unless error.code == "duplicate_identity" && attempts.zero?

            attempts += 1
            retry
          end
        end

        def active_users
          @store.list_users(status: "active")
        end

        private

        def authenticate_once(provider_user_id, provider_data)
          @store.transaction do |store|
            identity = store.find_identity(
              provider: PROVIDER,
              provider_user_id: provider_user_id
            )

            if identity
              authenticate_existing(store, identity, provider_data)
            else
              create_user_and_identity(store, provider_user_id, provider_data)
            end
          end
        end

        def authenticate_existing(store, identity, provider_data)
          user = store.find_user(identity.user_id) || raise(Core::NotFound.new("user", identity.user_id))
          if user.status == "blocked"
            raise Core::Conflict.new(
              "user is blocked",
              code: "user_blocked",
              details: { user_id: user.id }
            )
          end

          now = current_time
          replacement = ExternalIdentity.new(
            id: identity.id,
            user_id: identity.user_id,
            provider: identity.provider,
            provider_user_id: identity.provider_user_id,
            provider_data: provider_data,
            created_at: identity.created_at,
            updated_at: now,
            last_authenticated_at: now,
            version: identity.version + 1
          )
          replacement = store.replace_identity(replacement, expected_version: identity.version)
          Authentication.new(user: user, identity: replacement, created: false)
        end

        def create_user_and_identity(store, provider_user_id, provider_data)
          now = current_time
          user = User.new(
            id: new_id,
            role: "client",
            status: "active",
            created_at: now
          )
          identity = ExternalIdentity.new(
            id: new_id,
            user_id: user.id,
            provider: PROVIDER,
            provider_user_id: provider_user_id,
            provider_data: provider_data,
            created_at: now
          )

          store.insert_user(user)
          store.insert_identity(identity)
          Authentication.new(user: user, identity: identity, created: true)
        end

        def normalize_telegram_id(value)
          normalized = value.to_s
          unless TELEGRAM_ID_PATTERN.match?(normalized)
            raise ArgumentError, "telegram_user_id must be a positive integer"
          end

          normalized.freeze
        end

        def new_id
          value = @id_generator.call
          Core::RecordSupport.identifier(value, field: "generated id")
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
