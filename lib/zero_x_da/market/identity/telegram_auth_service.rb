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
        AUTHENTICATABLE_ROLES = %w[client broker].freeze
        ROLE_RANK = { "client" => 0, "broker" => 1, "admin" => 2 }.freeze

        def initialize(
          store:,
          clock: -> { Time.now.utc },
          id_generator: SecureRandom.method(:uuid)
        )
          @store = store
          @clock = clock
          @id_generator = id_generator
        end

        def authenticate(provider_user_id:, provider_data: {}, role: "client")
          provider_user_id = normalize_telegram_id(provider_user_id)
          provider_data = Core::RecordSupport.document(provider_data, field: "provider data")
          role = normalize_role(role)
          attempts = 0

          begin
            authenticate_once(provider_user_id, provider_data, role)
          rescue Core::Conflict => error
            raise unless error.code == "duplicate_identity" && attempts.zero?

            attempts += 1
            retry
          end
        end

        def active_users
          @store.list_users(status: "active")
        end

        def set_admin(actor_provider_user_id:, target:)
          actor_provider_user_id = normalize_telegram_id(actor_provider_user_id)

          @store.transaction do |store|
            actor_identity = store.find_identity(
              provider: PROVIDER,
              provider_user_id: actor_provider_user_id
            ) || raise(Core::NotFound.new("telegram_identity", actor_provider_user_id))
            actor = fetch_active_user(store, actor_identity.user_id)
            unless actor.role == "admin"
              raise Core::Forbidden.new(
                "admin role is required",
                details: { user_id: actor.id }
              )
            end

            identity = resolve_target_identity(store, target)
            user = fetch_active_user(store, identity.user_id)
            changed = user.role != "admin"
            user = promote_user(store, user) if changed
            RoleAssignment.new(
              user: user,
              identity: identity,
              actor: actor,
              changed: changed
            )
          end
        end

        # Resolves the telegram identity and raises unless the user is an
        # active admin. Shared guard for admin-only transport routes.
        def require_admin(provider_user_id:)
          provider_user_id = normalize_telegram_id(provider_user_id)

          @store.transaction do |store|
            identity = store.find_identity(
              provider: PROVIDER,
              provider_user_id: provider_user_id
            ) || raise(Core::NotFound.new("telegram_identity", provider_user_id))
            user = fetch_active_user(store, identity.user_id)
            unless user.role == "admin"
              raise Core::Forbidden.new(
                "admin role is required",
                details: { user_id: user.id }
              )
            end

            user
          end
        end

        private

        def authenticate_once(provider_user_id, provider_data, role)
          @store.transaction do |store|
            identity = store.find_identity(
              provider: PROVIDER,
              provider_user_id: provider_user_id
            )

            if identity
              authenticate_existing(store, identity, provider_data, role)
            else
              create_user_and_identity(store, provider_user_id, provider_data, role)
            end
          end
        end

        def authenticate_existing(store, identity, provider_data, role)
          user = store.find_user(identity.user_id) || raise(Core::NotFound.new("user", identity.user_id))
          if user.status == "blocked"
            raise Core::Conflict.new(
              "user is blocked",
              code: "user_blocked",
              details: { user_id: user.id }
            )
          end

          user = assign_role(store, user, role)

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

        def create_user_and_identity(store, provider_user_id, provider_data, role)
          now = current_time
          user = User.new(
            id: new_id,
            role: role,
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

        def resolve_target_identity(store, target)
          normalized = target.to_s.strip
          raise ArgumentError, "target must not be empty" if normalized.empty?

          identity = if normalized.start_with?("@")
                       username = normalized.delete_prefix("@").strip
                       unless username.match?(/\A[A-Za-z0-9_]{5,32}\z/)
                         raise ArgumentError, "target username is invalid"
                       end
                       store.find_identity_by_username(
                         provider: PROVIDER,
                         username: username
                       )
                     else
                       store.find_identity(
                         provider: PROVIDER,
                         provider_user_id: normalize_telegram_id(normalized)
                       )
                     end
          identity || raise(Core::NotFound.new("telegram_identity", normalized))
        end

        def fetch_active_user(store, id)
          user = store.find_user(id) || raise(Core::NotFound.new("user", id))
          if user.status != "active"
            raise Core::Conflict.new(
              "user is not active",
              code: "user_not_active",
              details: { user_id: user.id }
            )
          end
          user
        end

        def promote_user(store, user)
          replace_role(store, user, "admin")
        end

        def assign_role(store, user, role)
          return user if ROLE_RANK.fetch(user.role) >= ROLE_RANK.fetch(role)

          replace_role(store, user, role)
        end

        def replace_role(store, user, role)
          replacement = User.new(
            id: user.id,
            role: role,
            status: user.status,
            created_at: user.created_at,
            updated_at: current_time,
            version: user.version + 1
          )
          store.replace_user(replacement, expected_version: user.version)
        end

        def normalize_role(value)
          role = value.to_s
          unless AUTHENTICATABLE_ROLES.include?(role)
            raise ArgumentError, "authentication role is invalid"
          end

          role.freeze
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
