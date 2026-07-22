#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  switch-environment.sh status
  switch-environment.sh development
  CONFIRM_PRODUCTION=1 switch-environment.sh production

Environment overrides:
  CORE_DEPLOY_PATH   default: /opt/0xda-market
  BOT_DEPLOY_PATH    default: /opt/0xda-market-bot
  VPS_RUNTIME_PATH   default: /opt/0xda-market-runtime
USAGE
}

core_root="${CORE_DEPLOY_PATH:-/opt/0xda-market}"
bot_root="${BOT_DEPLOY_PATH:-/opt/0xda-market-bot}"
runtime_root="${VPS_RUNTIME_PATH:-/opt/0xda-market-runtime}"
state_file="$runtime_root/active-environment"
command="${1:-}"

environment_root() {
  local root="$1"
  local environment="$2"
  printf '%s/environments/%s' "$root" "$environment"
}

current_release() {
  local root="$1"
  local environment="$2"
  readlink -f "$(environment_root "$root" "$environment")/current" 2>/dev/null || true
}

validate_environment() {
  local root="$1"
  local environment="$2"
  local label="$3"
  local env_root release env_file

  env_root="$(environment_root "$root" "$environment")"
  release="$(current_release "$root" "$environment")"
  env_file="$env_root/shared/.env"

  if [[ -z "$release" || ! -d "$release/deploy/vps" ]]; then
    echo "$label $environment release is not staged" >&2
    return 1
  fi

  if [[ ! -f "$env_file" ]]; then
    echo "$label $environment runtime file is missing: $env_file" >&2
    return 1
  fi

  if ! grep -qx "DEPLOY_ENV=$environment" "$env_file"; then
    echo "$label $environment runtime file must contain DEPLOY_ENV=$environment" >&2
    return 1
  fi
}

compose_down() {
  local root="$1"
  local environment="$2"
  local release

  release="$(current_release "$root" "$environment")"
  [[ -n "$release" && -d "$release/deploy/vps" ]] || return 0

  (
    cd "$release/deploy/vps"
    docker compose down --remove-orphans
  )
}

activate_release() {
  local root="$1"
  local environment="$2"
  local release

  release="$(current_release "$root" "$environment")"
  DEPLOY_MODE=activate bash "$release/deploy/vps/deploy.sh"
}

write_active_environment() {
  local environment="$1"
  local temporary

  install -d -m 0750 "$runtime_root"
  temporary="$(mktemp "$runtime_root/active-environment.XXXXXX")"
  printf '%s\n' "$environment" >"$temporary"
  chmod 0640 "$temporary"
  mv -f "$temporary" "$state_file"
}

show_status() {
  local active="none"
  [[ -f "$state_file" ]] && active="$(<"$state_file")"

  printf 'active_environment=%s\n' "$active"
  for environment in development production; do
    printf '%s_core=%s\n' "$environment" "$(current_release "$core_root" "$environment")"
    printf '%s_bot=%s\n' "$environment" "$(current_release "$bot_root" "$environment")"
  done
}

rollback_to() {
  local previous="$1"

  [[ "$previous" == "development" || "$previous" == "production" ]] || return 1

  echo "Rolling back to $previous" >&2
  activate_release "$core_root" "$previous"
  activate_release "$bot_root" "$previous"
}

switch_environment() {
  local target="$1"
  local previous=""
  local other

  case "$target" in
    development|production) ;;
    *)
      echo "Unknown environment: $target" >&2
      usage >&2
      return 2
      ;;
  esac

  if [[ "$target" == "production" && "${CONFIRM_PRODUCTION:-0}" != "1" ]]; then
    echo "Production switch requires CONFIRM_PRODUCTION=1" >&2
    return 2
  fi

  validate_environment "$core_root" "$target" "core"
  validate_environment "$bot_root" "$target" "bot"

  if [[ -f "$state_file" ]]; then
    previous="$(<"$state_file")"
  fi

  if [[ "$previous" == "$target" ]]; then
    echo "$target is already active; refreshing the current releases"
    activate_release "$core_root" "$target"
    activate_release "$bot_root" "$target"
    write_active_environment "$target"
    echo "$target is healthy"
    return 0
  fi

  for other in development production; do
    [[ "$other" == "$target" ]] && continue
    compose_down "$bot_root" "$other"
    compose_down "$core_root" "$other"
  done

  if ! activate_release "$core_root" "$target"; then
    echo "Core activation failed for $target" >&2
    compose_down "$core_root" "$target" || true
    rollback_to "$previous" || true
    return 1
  fi

  if ! activate_release "$bot_root" "$target"; then
    echo "Bot activation failed for $target" >&2
    compose_down "$bot_root" "$target" || true
    compose_down "$core_root" "$target" || true
    rollback_to "$previous" || true
    return 1
  fi

  write_active_environment "$target"
  echo "$target is now active"
}

case "$command" in
  status)
    show_status
    ;;
  development|production)
    switch_environment "$command"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
