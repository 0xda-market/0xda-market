# frozen_string_literal: true

require "monitor"
require_relative "../core/contracts"

module ZeroXDA
  module Market
    module Identity
      class MemoryStore
        def initialize
          @users = {}
          @identities = {}
          @monitor = Monitor.new
        end

        def transaction
          @monitor.synchronize do
            users = @users.dup
            identities = @identities.dup
            committed = false
            begin
              result = yield self
              committed = true
              result
            ensure
              unless committed
                @users = users
                @identities = identities
              end
            end
          end
        end

        def find_user(id)
          @monitor.synchronize { @users[id.to_s] }
        end

        def find_identity(provider:, provider_user_id:)
          @monitor.synchronize do
            @identities.values.find do |identity|
              identity.provider == provider && identity.provider_user_id == provider_user_id.to_s
            end
          end
        end

        def find_identity_by_username(provider:, username:)
          @monitor.synchronize do
            @identities.values.find do |identity|
              identity.provider == provider &&
                identity.provider_data["username"].to_s.casecmp?(username.to_s)
            end
          end
        end

        def list_users(status:)
          @monitor.synchronize do
            @users.values
                  .select { |user| user.status == status }
                  .sort_by(&:created_at)
                  .filter_map do |user|
              identity = @identities.values.find do |item|
                item.user_id == user.id && item.provider == "telegram"
              end
              UserIdentity.new(user: user, identity: identity) if identity
            end
          end
        end

        def insert_user(user)
          @monitor.synchronize do
            raise duplicate("user", user.id) if @users.key?(user.id)

            @users[user.id] = user
          end
          user
        end

        def replace_user(user, expected_version:)
          @monitor.synchronize do
            current = @users[user.id]
            raise Core::NotFound.new("user", user.id) unless current
            unless current.version == expected_version
              raise Core::ConcurrencyConflict.new("user", user.id)
            end

            @users[user.id] = user
          end
          user
        end

        def insert_identity(identity)
          @monitor.synchronize do
            existing = find_identity(
              provider: identity.provider,
              provider_user_id: identity.provider_user_id
            )
            raise duplicate_identity(identity) if existing

            same_provider = @identities.values.any? do |item|
              item.user_id == identity.user_id && item.provider == identity.provider
            end
            raise duplicate_identity(identity) if same_provider

            @identities[identity.id] = identity
          end
          identity
        end

        def replace_identity(identity, expected_version:)
          @monitor.synchronize do
            current = @identities[identity.id]
            raise Core::NotFound.new("user_identity", identity.id) unless current
            unless current.version == expected_version
              raise Core::ConcurrencyConflict.new("user_identity", identity.id)
            end

            @identities[identity.id] = identity
          end
          identity
        end

        private

        def duplicate(resource, id)
          Core::Conflict.new(
            "#{resource} already exists",
            code: "duplicate_record",
            details: { resource: resource, id: id }
          )
        end

        def duplicate_identity(identity)
          Core::Conflict.new(
            "provider identity already exists",
            code: "duplicate_identity",
            details: {
              provider: identity.provider,
              provider_user_id: identity.provider_user_id
            }
          )
        end
      end
    end
  end
end
