#!/usr/bin/env bash

set -euo pipefail

required_variables=(
  RENDER_API_KEY
  RENDER_API_URL
  RENDER_PROJECT_NAME
  RENDER_TEST_ENVIRONMENT_NAME
  TEST_SERVICE_NAME
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "$variable_name is missing" >&2
    exit 1
  fi
done

render_get() {
  local path="$1"
  shift

  curl --fail-with-body --silent --show-error \
    --get \
    --header "Authorization: Bearer $RENDER_API_KEY" \
    --header "Accept: application/json" \
    "$RENDER_API_URL$path" \
    "$@"
}

services_json="$(render_get /services \
  --data-urlencode "name=$TEST_SERVICE_NAME" \
  --data-urlencode "limit=20")"
services="$(jq --arg name "$TEST_SERVICE_NAME" \
  '[.[] | .service | select(.name == $name)]' <<<"$services_json")"
service_count="$(jq 'length' <<<"$services")"

if [[ "$service_count" != "1" ]]; then
  echo "Expected one Render service named '$TEST_SERVICE_NAME'; found $service_count." >&2
  exit 1
fi

service_id="$(jq -er '.[0].id' <<<"$services")"
owner_id="$(jq -er '.[0].ownerId' <<<"$services")"

projects_json="$(render_get /projects \
  --data-urlencode "ownerId=$owner_id" \
  --data-urlencode "name=$RENDER_PROJECT_NAME" \
  --data-urlencode "limit=20")"
projects="$(jq --arg name "$RENDER_PROJECT_NAME" \
  '[.[] | .project | select(.name == $name)]' <<<"$projects_json")"
project_count="$(jq 'length' <<<"$projects")"

if [[ "$project_count" != "1" ]]; then
  echo "Expected one Render project named '$RENDER_PROJECT_NAME'; found $project_count." >&2
  exit 1
fi

project_id="$(jq -er '.[0].id' <<<"$projects")"
environments_json="$(render_get /environments \
  --data-urlencode "projectId=$project_id" \
  --data-urlencode "name=$RENDER_TEST_ENVIRONMENT_NAME" \
  --data-urlencode "limit=20")"
environments="$(jq --arg name "$RENDER_TEST_ENVIRONMENT_NAME" \
  '[.[] | .environment | select(.name == $name)]' <<<"$environments_json")"
environment_count="$(jq 'length' <<<"$environments")"

case "$environment_count" in
  0)
    request_body="$(jq -n \
      --arg name "$RENDER_TEST_ENVIRONMENT_NAME" \
      --arg project_id "$project_id" \
      '{name: $name, projectId: $project_id}')"
    environment="$(curl --fail-with-body --silent --show-error \
      --request POST \
      --header "Authorization: Bearer $RENDER_API_KEY" \
      --header "Content-Type: application/json" \
      --data "$request_body" \
      "$RENDER_API_URL/environments")"
    echo "Created Render environment '$RENDER_PROJECT_NAME / $RENDER_TEST_ENVIRONMENT_NAME'."
    ;;
  1)
    environment="$(jq -c '.[0]' <<<"$environments")"
    ;;
  *)
    echo "Expected at most one Render environment named '$RENDER_TEST_ENVIRONMENT_NAME' in project '$RENDER_PROJECT_NAME'; found $environment_count." >&2
    exit 1
    ;;
esac

environment_id="$(jq -er '.id' <<<"$environment")"

if jq -e --arg service_id "$service_id" '.serviceIds | index($service_id) != null' \
  <<<"$environment" > /dev/null; then
  echo "Render service '$TEST_SERVICE_NAME' is already in '$RENDER_PROJECT_NAME / $RENDER_TEST_ENVIRONMENT_NAME'."
else
  request_body="$(jq -n --arg service_id "$service_id" '{resourceIds: [$service_id]}')"
  environment="$(curl --fail-with-body --silent --show-error \
    --request POST \
    --header "Authorization: Bearer $RENDER_API_KEY" \
    --header "Content-Type: application/json" \
    --data "$request_body" \
    "$RENDER_API_URL/environments/$environment_id/resources")"

  jq -e --arg service_id "$service_id" \
    '.serviceIds | index($service_id) != null' <<<"$environment" > /dev/null
  echo "Moved Render service '$TEST_SERVICE_NAME' to '$RENDER_PROJECT_NAME / $RENDER_TEST_ENVIRONMENT_NAME'."
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Render project"
    echo
    echo "- Project: \`$RENDER_PROJECT_NAME\`"
    echo "- Environment: \`$RENDER_TEST_ENVIRONMENT_NAME\`"
    echo "- Service: \`$TEST_SERVICE_NAME\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
