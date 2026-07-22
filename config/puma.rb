# frozen_string_literal: true

port = Integer(ENV.fetch("PORT", "10000"), 10)
threads_count = Integer(ENV.fetch("PUMA_THREADS", "5"), 10)

bind "tcp://0.0.0.0:#{port}"
environment ENV.fetch("DEPLOY_ENV", "development")
threads threads_count, threads_count

# Development memory adapters are process-local. Keep a single Puma process;
# production state remains durable through PostgreSQL.
workers 0
