# frozen_string_literal: true

require_relative "../core/records"

module ZeroXDA
  module Market
    module Identity
      class User
        ROLES = %w[client broker admin].freeze
        STATUSES = %w[active blocked].freeze

        attr_reader :id, :role, :status, :created_at, :updated_at, :version

        def initialize(id:, role:, status:, created_at:, updated_at: created_at, version: 0)
          raise ArgumentError, "user role is invalid" unless ROLES.include?(role)
          raise ArgumentError, "user status is invalid" unless STATUSES.include?(status)

          @id = Core::RecordSupport.identifier(id, field: "user id")
          @role = role.dup.freeze
          @status = status.dup.freeze
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end
      end

      class ExternalIdentity
        attr_reader :id,
                    :user_id,
                    :provider,
                    :provider_user_id,
                    :provider_data,
                    :created_at,
                    :updated_at,
                    :last_authenticated_at,
                    :version

        def initialize(
          id:,
          user_id:,
          provider:,
          provider_user_id:,
          provider_data: {},
          created_at:,
          updated_at: created_at,
          last_authenticated_at: created_at,
          version: 0
        )
          @id = Core::RecordSupport.identifier(id, field: "identity id")
          @user_id = Core::RecordSupport.identifier(user_id, field: "user id")
          @provider = Core::RecordSupport.identifier(provider, field: "provider")
          @provider_user_id = Core::RecordSupport.identifier(
            provider_user_id,
            field: "provider user id"
          )
          @provider_data = Core::RecordSupport.document(provider_data, field: "provider data")
          @created_at = Core::RecordSupport.time(created_at, field: "created_at")
          @updated_at = Core::RecordSupport.time(updated_at, field: "updated_at")
          @last_authenticated_at = Core::RecordSupport.time(
            last_authenticated_at,
            field: "last_authenticated_at"
          )
          @version = Core::RecordSupport.non_negative_integer(version, field: "version")
          freeze
        end
      end

      Authentication = Data.define(:user, :identity, :created)
      UserIdentity = Data.define(:user, :identity)
      RoleAssignment = Data.define(:user, :identity, :actor, :changed)
    end
  end
end
