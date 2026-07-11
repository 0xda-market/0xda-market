# frozen_string_literal: true

require "digest"
require "uri"
require_relative "records"

module ZeroXDA
  module Market
    module Telegram
      class Configuration
        ENVIRONMENT_KEYS = {
          client_token: "TELEGRAM_CLIENT_BOT_TOKEN",
          broker_token: "TELEGRAM_BROKER_BOT_TOKEN",
          base_url: "TELEGRAM_WEBHOOK_BASE_URL"
        }.freeze

        attr_reader :client_token, :broker_token, :base_url

        def self.from_env(environment = ENV)
          values = ENVIRONMENT_KEYS.transform_values { |key| environment[key] }
          return nil if values.values.all? { |value| value.nil? || value.empty? }

          missing = values.filter_map do |name, value|
            ENVIRONMENT_KEYS.fetch(name) if value.nil? || value.empty?
          end
          unless missing.empty?
            raise ArgumentError, "incomplete Telegram configuration: #{missing.join(", ")}"
          end

          new(**values)
        end

        def initialize(client_token:, broker_token:, base_url:)
          @client_token = required(client_token, "client bot token")
          @broker_token = required(broker_token, "broker bot token")
          @base_url = normalize_base_url(base_url)
          freeze
        end

        def token(role)
          case role.to_s
          when "client" then client_token
          when "broker" then broker_token
          else raise ArgumentError, "Telegram bot role is invalid"
          end
        end

        def endpoint(role)
          normalized = normalize_role(role)
          "#{base_url}/telegram/#{normalized}"
        end

        def secret_token(role)
          normalized = normalize_role(role)
          Digest::SHA256.hexdigest("zeroxda-market/#{normalized}/#{token(normalized)}")
        end

        private

        def normalize_base_url(value)
          raw = required(value, "Telegram webhook base URL").delete_suffix("/")
          uri = URI.parse(raw)
          unless uri.is_a?(URI::HTTPS) && uri.host && uri.path.to_s.match?(%r{\A/?\z}) &&
                 uri.query.nil? && uri.fragment.nil?
            raise ArgumentError, "Telegram webhook base URL must be an HTTPS origin"
          end

          raw.freeze
        rescue URI::InvalidURIError
          raise ArgumentError, "Telegram webhook base URL must be an HTTPS origin"
        end

        def normalize_role(role)
          normalized = role.to_s
          raise ArgumentError, "Telegram bot role is invalid" unless BOT_ROLES.include?(normalized)

          normalized
        end

        def required(value, field)
          unless value.is_a?(String) && !value.empty?
            raise ArgumentError, "#{field} must be a non-empty string"
          end

          value.dup.freeze
        end
      end
    end
  end
end
