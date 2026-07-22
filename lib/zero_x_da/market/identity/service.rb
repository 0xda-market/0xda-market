# frozen_string_literal: true

require "securerandom"
require_relative "../core/contracts"
require_relative "records"

module ZeroXDA
  module Market
    module Identity
      class Service
        PROVIDER_PATTERN = /\A[a-z][a-z0-9._-]{0,63}\z/
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

        def authenticate(provider:, provider_user_id:, provider_data: {}, role: "client")
          provider = normalize_provider(provider)
          provider_user_id = normalize_provider_user_id(provider_user_id)
          provider_data = Core::RecordSupport.document(provider_data, field: "provider data")
          role = normalize_role(role)
          attempts = 0

          begin
            authenticate_once(provider, provider_user_id, provider_data, role)
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

        def authenticate_once(provider, provider_user_id, provider_data, role)
          @store.transaction do |store|
            identity = store.find_identity(
              provider: provider,
              provider_user_id: provider_user_id
            )

            if identity
              authenticate_existing(store, identity, provider_data, role)
            else
              create_user_and_identity(store, provider, provider_user_id, provider_data, role)
            end
          end
        end

        def authenticate_existing(store, identity, provider_data, role)
          user = fetch_active_user(store, identity.user_id)
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

        def create_user_and_identity(store, provider, provider_user_id, provider_data, role)
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
            provider: provider,
            provider_user_id: provider_user_id,
            provider_data: provider_data,
            created_at: now
          )

          store.insert_user(user)
          store.insert_identity(identity)
          Authentication.new(user: user, identity: identity, created: true)
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

        def assign_role(store, user, role)
          return user if ROLE_RANK.fetch(user.role) >= ROLE_RANK.fetch(role)

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

        def normalize_provider(value)
          provider = value.to_s
          unless PROVIDER_PATTERN.match?(provider)
            raise ArgumentError, "provider must be a lowercase identifier"
          end

          provider.freeze
        end

        def normalize_provider_user_id(value)
          identifier = value.to_s
          raise ArgumentError, "provider_user_id must not be empty" if identifier.empty?
          raise ArgumentError, "provider_user_id is too long" if identifier.bytesize > 256

          identifier.freeze
        end

        def normalize_role(value)
          role = value.to_s
          unless AUTHENTICATABLE_ROLES.include?(role)
            raise ArgumentError, "authentication role is invalid"
          end

          role.freeze
        end

        def new_id
          Core::RecordSupport.identifier(@id_generator.call, field: "generated id")
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
