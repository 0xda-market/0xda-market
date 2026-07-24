# syntax=docker/dockerfile:1

FROM ruby:3.3.11-slim AS build

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle

WORKDIR /app

RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

COPY . .
RUN bundle exec rake \
    && BUNDLE_PATH=/usr/local/bundle-production \
       BUNDLE_WITHOUT=development:test \
       bundle install --jobs 4 --retry 3

FROM ruby:3.3.11-slim AS runtime

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    PORT=10000

WORKDIR /app

RUN apt-get update \
    && apt-get install --yes --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system app \
    && useradd --system --gid app --home-dir /app app

COPY --from=build /usr/local/bundle-production /usr/local/bundle
COPY --from=build --chown=app:app /app/Gemfile /app/Gemfile.lock /app/config.ru ./
COPY --from=build --chown=app:app /app/config ./config
COPY --from=build --chown=app:app /app/lib ./lib
COPY --from=build --chown=app:app /app/bin ./bin
COPY --from=build --chown=app:app /app/db ./db

USER app

EXPOSE 10000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD ["ruby", "-rnet/http", "-e", "uri = URI('http://127.0.0.1:' + ENV.fetch('PORT', '10000') + '/health'); exit(Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess) ? 0 : 1)"]

CMD ["sh", "-c", "bundle exec ruby bin/migrate && exec bundle exec puma -C config/puma.rb"]
