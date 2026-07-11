# frozen_string_literal: true

port = Integer(ENV.fetch("PORT", "10000"), 10)
threads_count = Integer(ENV.fetch("PUMA_THREADS", "5"), 10)

bind "tcp://0.0.0.0:#{port}"
environment ENV.fetch("RACK_ENV", "development")
threads threads_count, threads_count

# MemoryStore and ManualProvider are process-local. Keep a single Puma process
# until both adapters are backed by durable shared storage.
workers 0
