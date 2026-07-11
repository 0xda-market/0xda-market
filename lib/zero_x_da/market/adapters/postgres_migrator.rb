# frozen_string_literal: true

require "digest"
require_relative "postgres_database"

module ZeroXDA
  module Market
    module Adapters
      class PostgresMigrator
        LOCK_ID = 7_964_013_417

        def initialize(database:, path:)
          @database = database.connection
          @path = path
        end

        def migrate!
          @database.run("CREATE SCHEMA IF NOT EXISTS market")
          @database.run(<<~SQL)
            CREATE TABLE IF NOT EXISTS market.schema_migrations (
              version text PRIMARY KEY,
              checksum text NOT NULL,
              applied_at timestamptz NOT NULL DEFAULT now()
            )
          SQL

          @database.transaction do
            @database.fetch("SELECT pg_advisory_xact_lock(?)", LOCK_ID).all
            migration_files.each { |file| apply_migration(file) }
          end
        end

        private

        def migration_files
          Dir[File.join(@path, "*.sql")].sort
        end

        def apply_migration(file)
          version = File.basename(file, ".sql")
          sql = File.read(file)
          checksum = Digest::SHA256.hexdigest(sql)
          existing = migrations.where(version: version).get(:checksum)

          if existing
            return if existing == checksum

            raise "migration checksum changed: #{version}"
          end

          @database.run(sql)
          migrations.insert(version: version, checksum: checksum)
        end

        def migrations
          @database[Sequel.qualify(:market, :schema_migrations)]
        end
      end
    end
  end
end
