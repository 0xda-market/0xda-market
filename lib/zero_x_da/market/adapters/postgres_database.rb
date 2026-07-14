# frozen_string_literal: true

require "sequel"

module ZeroXDA
  module Market
    module Adapters
      class PostgresDatabase
        attr_reader :connection

        def initialize(url:, max_connections: 5)
          @connection = Sequel.connect(
            url,
            max_connections: max_connections,
            test: false
          )
          @connection.extension(
            :pg_json,
            :connection_validator,
            :transaction_connection_validator
          )
          @connection.pool.connection_validation_timeout = 30
        end

        def healthy?
          connection.fetch("SELECT 1 AS value").get(:value) == 1
        rescue Sequel::DatabaseError
          false
        end

        def disconnect
          connection.disconnect
        end
      end
    end
  end
end
