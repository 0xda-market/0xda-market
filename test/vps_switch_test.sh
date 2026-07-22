#!/usr/bin/env bash
set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
switch_script="$repository_root/deploy/vps/switch-environment.sh"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

export TEST_LOG="$temporary_root/events.log"
export CORE_DEPLOY_PATH="$temporary_root/core"
export BOT_DEPLOY_PATH="$temporary_root/bot"
export VPS_RUNTIME_PATH="$temporary_root/runtime"
export PATH="$temporary_root/bin:$PATH"

mkdir -p "$temporary_root/bin"
cat >"$temporary_root/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf 'docker:%s\n' "$*" >>"$TEST_LOG"
DOCKER
chmod +x "$temporary_root/bin/docker"

stage_release() {
  local root="$1"
  local environment="$2"
  local component="$3"
  local release="$root/environments/$environment/releases/release-1"

  mkdir -p "$release/deploy/vps" "$root/environments/$environment/shared"
  printf 'DEPLOY_ENV=%s\n' "$environment" >"$root/environments/$environment/shared/.env"
  ln -sfn "$root/environments/$environment/shared/.env" "$release/deploy/vps/.env"
  cat >"$release/deploy/vps/deploy.sh" <<SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
printf '${component}:${environment}:%s\n' "\${DEPLOY_MODE:-activate}" >>"\$TEST_LOG"
if [[ "\${FAIL_COMPONENT:-}" == "${component}" && "\${FAIL_ENVIRONMENT:-}" == "${environment}" ]]; then
  exit 1
fi
SCRIPT
  ln -sfn "$release" "$root/environments/$environment/current"
}

for environment in development production; do
  stage_release "$CORE_DEPLOY_PATH" "$environment" core
  stage_release "$BOT_DEPLOY_PATH" "$environment" bot
done

bash "$switch_script" development
[[ "$(<"$VPS_RUNTIME_PATH/active-environment")" == "development" ]]
grep -qx 'core:development:activate' "$TEST_LOG"
grep -qx 'bot:development:activate' "$TEST_LOG"

if bash "$switch_script" production 2>/dev/null; then
  echo "production switch unexpectedly succeeded without confirmation" >&2
  exit 1
fi
[[ "$(<"$VPS_RUNTIME_PATH/active-environment")" == "development" ]]

export FAIL_COMPONENT=bot
export FAIL_ENVIRONMENT=production
if CONFIRM_PRODUCTION=1 bash "$switch_script" production 2>/dev/null; then
  echo "production switch unexpectedly succeeded with a failing bot" >&2
  exit 1
fi
[[ "$(<"$VPS_RUNTIME_PATH/active-environment")" == "development" ]]
[[ "$(grep -c '^core:development:activate$' "$TEST_LOG")" -ge 2 ]]
[[ "$(grep -c '^bot:development:activate$' "$TEST_LOG")" -ge 2 ]]

unset FAIL_COMPONENT FAIL_ENVIRONMENT
CONFIRM_PRODUCTION=1 bash "$switch_script" production
[[ "$(<"$VPS_RUNTIME_PATH/active-environment")" == "production" ]]

echo "VPS environment switch tests passed"
