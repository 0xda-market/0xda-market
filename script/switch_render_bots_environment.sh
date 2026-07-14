#!/usr/bin/env bash

set -euo pipefail

required_variables=(
  RENDER_API_KEY
  RENDER_API_URL
  TEST_SERVICE_NAME
  PRODUCTION_SERVICE_NAME
  CLIENT_SERVICE_NAME
  BROKER_SERVICE_NAME
  TARGET_ENVIRONMENT
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "$variable_name is missing" >&2
    exit 1
  fi
done

case "$TARGET_ENVIRONMENT" in
  test) core_service_name="$TEST_SERVICE_NAME" ;;
  production) core_service_name="$PRODUCTION_SERVICE_NAME" ;;
  *)
    echo "TARGET_ENVIRONMENT must be 'test' or 'production'." >&2
    exit 1
    ;;
esac

find_service() {
  local name="$1"
  local services_json
  local matches
  local match_count

  services_json="$(curl --fail-with-body --silent --show-error \
    --get \
    --header "Authorization: Bearer $RENDER_API_KEY" \
    --header "Accept: application/json" \
    --data-urlencode "name=$name" \
    --data-urlencode "limit=20" \
    "$RENDER_API_URL/services")"
  matches="$(jq --arg name "$name" \
    '[.[] | .service | select(.name == $name)]' <<<"$services_json")"
  match_count="$(jq 'length' <<<"$matches")"
  if [[ "$match_count" != "1" ]]; then
    echo "Expected one Render service named '$name'; found $match_count." >&2
    exit 1
  fi

  jq -c '.[0]' <<<"$matches"
}

read_env() {
  local service_id="$1"
  local key="$2"

  curl --fail-with-body --silent --show-error \
    --header "Authorization: Bearer $RENDER_API_KEY" \
    "$RENDER_API_URL/services/$service_id/env-vars/$key" \
    | jq -er '.value'
}

put_env() {
  local service_id="$1"
  local key="$2"
  local value="$3"
  local body

  body="$(jq -n --arg value "$value" '{value: $value}')"
  curl --fail-with-body --silent --show-error \
    --request PUT \
    --header "Authorization: Bearer $RENDER_API_KEY" \
    --header "Content-Type: application/json" \
    --data "$body" \
    "$RENDER_API_URL/services/$service_id/env-vars/$key" \
    > /dev/null
}

deploy_and_wait() {
  local service_id="$1"
  local service_name="$2"
  local deploy_json
  local deploy_id
  local deploy_status=""

  deploy_json="$(curl --fail-with-body --silent --show-error \
    --request POST \
    --header "Authorization: Bearer $RENDER_API_KEY" \
    --header "Content-Type: application/json" \
    --data '{"clearCache":"do_not_clear"}' \
    "$RENDER_API_URL/services/$service_id/deploys")"
  deploy_id="$(jq -er '.id' <<<"$deploy_json")"

  for _ in {1..90}; do
    deploy_json="$(curl --fail-with-body --silent --show-error \
      --header "Authorization: Bearer $RENDER_API_KEY" \
      "$RENDER_API_URL/services/$service_id/deploys/$deploy_id")"
    deploy_status="$(jq -r '.status' <<<"$deploy_json")"
    case "$deploy_status" in
      live) break ;;
      build_failed|update_failed|pre_deploy_failed|canceled|deactivated)
        echo "Render deploy for '$service_name' failed with status: $deploy_status" >&2
        exit 1
        ;;
    esac
    sleep 10
  done

  if [[ "$deploy_status" != "live" ]]; then
    echo "Timed out waiting for '$service_name'; last status: $deploy_status" >&2
    exit 1
  fi

  echo "$deploy_id"
}

verify_health() {
  local service_slug="$1"

  curl --fail --silent --show-error \
    --retry 12 \
    --retry-delay 5 \
    --retry-all-errors \
    "https://$service_slug.onrender.com/health" > /dev/null
}

verify_webhook() {
  local telegram_token="$1"
  local expected_url="$2"
  local response
  local actual_url

  response="$(curl --fail-with-body --silent --show-error \
    --retry 12 \
    --retry-delay 5 \
    --retry-all-errors \
    "https://api.telegram.org/bot$telegram_token/getWebhookInfo")"
  jq -e '.ok == true' <<<"$response" > /dev/null
  actual_url="$(jq -r '.result.url' <<<"$response")"
  if [[ "$actual_url" != "$expected_url" ]]; then
    echo "Telegram webhook mismatch: expected '$expected_url', got '$actual_url'." >&2
    exit 1
  fi
}

core_service="$(find_service "$core_service_name")"
core_service_id="$(jq -er '.id' <<<"$core_service")"
core_slug="$(jq -er '.slug' <<<"$core_service")"
market_api_url="https://$core_slug.onrender.com"
public_api_token="$(read_env "$core_service_id" PUBLIC_API_TOKEN)"
manual_provider_token="$(read_env "$core_service_id" MANUAL_PROVIDER_TOKEN)"
echo "::add-mask::$public_api_token"
echo "::add-mask::$manual_provider_token"
verify_health "$core_slug"

client_service="$(find_service "$CLIENT_SERVICE_NAME")"
client_service_id="$(jq -er '.id' <<<"$client_service")"
client_slug="$(jq -er '.slug' <<<"$client_service")"
client_telegram_token="$(read_env "$client_service_id" TELEGRAM_BOT_TOKEN)"
echo "::add-mask::$client_telegram_token"
put_env "$client_service_id" MARKET_API_URL "$market_api_url"
put_env "$client_service_id" MARKET_API_TOKEN "$public_api_token"
client_deploy_id="$(deploy_and_wait "$client_service_id" "$CLIENT_SERVICE_NAME")"
verify_health "$client_slug"
verify_webhook \
  "$client_telegram_token" \
  "https://$client_slug.onrender.com/telegram/webhook"

broker_service="$(find_service "$BROKER_SERVICE_NAME")"
broker_service_id="$(jq -er '.id' <<<"$broker_service")"
broker_slug="$(jq -er '.slug' <<<"$broker_service")"
broker_telegram_token="$(read_env "$broker_service_id" TELEGRAM_BOT_TOKEN)"
echo "::add-mask::$broker_telegram_token"
put_env "$broker_service_id" MARKET_API_URL "$market_api_url"
put_env "$broker_service_id" MARKET_OPERATOR_TOKEN "$manual_provider_token"
broker_deploy_id="$(deploy_and_wait "$broker_service_id" "$BROKER_SERVICE_NAME")"
verify_health "$broker_slug"
verify_webhook \
  "$broker_telegram_token" \
  "https://$broker_slug.onrender.com/telegram/webhook"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Telegram bot environment"
    echo
    echo "- Environment: \`$TARGET_ENVIRONMENT\`"
    echo "- Market API: $market_api_url"
    echo "- Client bot deploy: \`$client_deploy_id\`"
    echo "- Broker bot deploy: \`$broker_deploy_id\`"
    echo "- Health checks: \`passed\`"
    echo "- Telegram webhooks: \`verified\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
