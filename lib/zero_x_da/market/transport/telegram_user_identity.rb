# frozen_string_literal: true

module ZeroXDA
  module Market
    module Transport
      module TelegramUserIdentity
        private

        def present_user_identity(entry)
          resource = super
          provider_data = entry.identity.provider_data
          attributes = resource.fetch("attributes")
          attributes["telegram_username"] = provider_data["username"]
          attributes["telegram_first_name"] = provider_data["first_name"]
          attributes["telegram_last_name"] = provider_data["last_name"]
          resource
        end

        def present_role_assignment(assignment)
          resource = super
          provider_data = assignment.identity.provider_data
          attributes = resource.fetch("attributes")
          attributes["telegram_username"] = provider_data["username"]
          attributes["telegram_first_name"] = provider_data["first_name"]
          attributes["telegram_last_name"] = provider_data["last_name"]
          resource
        end
      end

      JSONAPI.prepend(TelegramUserIdentity)
    end
  end
end
