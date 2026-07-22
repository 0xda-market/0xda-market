# frozen_string_literal: true

require "sequel"
require_relative "../core/contracts"
require_relative "records"

module ZeroXDA
  module Market
    module Identity
      class PostgresStore
        def initialize(database:)
          @connection = database.connection
          @users = @connection[Sequel.qualify(:market, :users)]
          @identities = @connection[Sequel.qualify(:market, :user_identities)]
        end

        def transaction
          @connection.transaction(savepoint: true) { yield self }
        end

        def find_user(id)
          row = @users.where(id: id.to_s).first
          row && deserialize_user(row)
        end

        def find_identity(provider:, provider_user_id:)
          row = @identities.where(
            provider: provider,
            provider_user_id: provider_user_id.to_s
          ).first
          row && deserialize_identity(row)
        end

        def identities_for_user(user_id)
          @identities.where(user_id: user_id.to_s)
                     .order(:provider, :created_at)
                     .all
                     .map { |row| deserialize_identity(row) }
        end

        def list_users(status:)
          @users.where(status: status).order(:created_at).all.map do |row|
            UserProfile.new(
              user: deserialize_user(row),
              identities: identities_for_user(row.fetch(:id)).freeze
            )
          end
        end

        def insert_user(user)
          @users.insert(serialize_user(user))
          user
        rescue Sequel::UniqueConstraintViolation
          raise duplicate("user", user.id)
        end

        def replace_user(user, expected_version:)
          count = @users.where(id: user.id, version: expected_version)
                        .update(serialize_user(user))
          return user if count == 1

          raise Core::NotFound.new("user", user.id) unless @users.where(id: user.id).get(:id)

          raise Core::ConcurrencyConflict.new("user", user.id)
        end

        def insert_identity(identity)
          @identities.insert(serialize_identity(identity))
          identity
        rescue Sequel::UniqueConstraintViolation
          raise Core::Conflict.new(
            "provider identity already exists",
            code: "duplicate_identity",
            details: {
              provider: identity.provider,
              provider_user_id: identity.provider_user_id
            }
          )
        end

        def replace_identity(identity, expected_version:)
          count = @identities.where(id: identity.id, version: expected_version)
                             .update(serialize_identity(identity))
          return identity if count == 1

          raise Core::NotFound.new("user_identity", identity.id) unless @identities.where(id: identity.id).get(:id)

          raise Core::ConcurrencyConflict.new("user_identity", identity.id)
        end

        private

        def serialize_user(user)
          {
            id: user.id,
            role: user.role,
            status: user.status,
            created_at: user.created_at,
            updated_at: user.updated_at,
            version: user.version
          }
        end

        def deserialize_user(row)
          User.new(
            id: row.fetch(:id).to_s,
            role: row.fetch(:role),
            status: row.fetch(:status),
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            version: row.fetch(:version)
          )
        end

        def serialize_identity(identity)
          {
            id: identity.id,
            user_id: identity.user_id,
            provider: identity.provider,
            provider_user_id: identity.provider_user_id,
            provider_data: Sequel.pg_jsonb(identity.provider_data),
            created_at: identity.created_at,
            updated_at: identity.updated_at,
            last_authenticated_at: identity.last_authenticated_at,
            version: identity.version
          }
        end

        def deserialize_identity(row)
          ExternalIdentity.new(
            id: row.fetch(:id).to_s,
            user_id: row.fetch(:user_id).to_s,
            provider: row.fetch(:provider),
            provider_user_id: row.fetch(:provider_user_id),
            provider_data: document(row.fetch(:provider_data)),
            created_at: row.fetch(:created_at),
            updated_at: row.fetch(:updated_at),
            last_authenticated_at: row.fetch(:last_authenticated_at),
            version: row.fetch(:version)
          )
        end

        def document(value)
          value.respond_to?(:to_hash) ? value.to_hash : value
        end

        def duplicate(resource, id)
          Core::Conflict.new(
            "#{resource} already exists",
            code: "duplicate_record",
            details: { resource: resource, id: id }
          )
        end
      end
    end
  end
end
