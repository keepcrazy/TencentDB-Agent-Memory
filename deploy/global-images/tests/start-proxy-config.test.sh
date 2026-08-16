#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_IMAGES_DIR="$(dirname "$TEST_DIR")"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/bin"

cat > "$TMP_ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  network | run | rm | logs) exit 0 ;;
  ps)
    printf '%s\n' tdai-memory-core tdai-memory-hub
    exit 0
    ;;
  inspect)
    if [[ "$*" == *Health* ]]; then
      echo healthy
    else
      echo running
    fi
    exit 0
    ;;
esac

exit 0
SH
chmod +x "$TMP_ROOT/bin/docker"

write_env() {
  local target="$1"
  shift
  {
    printf '%s\n' \
      'PROXY_IMAGE=test/memory-proxy:latest' \
      'PROXY_PORT=18096' \
      'PROXY_UPSTREAM_URL=https://llm.example/v1' \
      'PROXY_UPSTREAM_API_KEY=test-key' \
      'PROXY_UPSTREAM_MODEL=test-model'
    printf '%s\n' "$@"
  } > "$target"
}

run_start() {
  local env_file="$1"
  local config_dir="$2"

  PATH="$TMP_ROOT/bin:$PATH" \
    ENV_FILE="$env_file" \
    PROXY_CONFIG_DIR="$config_dir" \
    bash "$GLOBAL_IMAGES_DIR/start-proxy.sh" >/dev/null 2>&1
}

extract_top_level_yaml_block() {
  local section="$1"
  local config_file="$2"

  awk -v header="${section}:" '
    $0 == header { found = 1; print; next }
    found && /^[^[:space:]#]/ { exit }
    found { print }
    END { if (!found) exit 1 }
  ' "$config_file"
}

test_explicit_external_gateway_url_is_written() {
  local case_dir="$TMP_ROOT/explicit"
  local env_file="$case_dir/.env"
  local config_dir="$case_dir/config"

  mkdir -p "$case_dir"
  write_env "$env_file" \
    'PROXY_EXTERNAL_GATEWAY_URL=https://memory.example.com'

  run_start "$env_file" "$config_dir"

  grep -F 'externalGatewayUrl: "https://memory.example.com"' "$config_dir/config.yaml" >/dev/null
}

test_default_external_gateway_url_uses_published_proxy_port() {
  local case_dir="$TMP_ROOT/default"
  local env_file="$case_dir/.env"
  local config_dir="$case_dir/config"

  mkdir -p "$case_dir"
  write_env "$env_file"

  run_start "$env_file" "$config_dir"

  grep -F 'externalGatewayUrl: "http://127.0.0.1:18096"' "$config_dir/config.yaml" >/dev/null
}

test_generated_config_disables_skill_extraction_but_keeps_memory_writes() {
  local case_dir="$TMP_ROOT/extraction"
  local env_file="$case_dir/.env"
  local config_dir="$case_dir/config"
  local expected actual

  mkdir -p "$case_dir"
  write_env "$env_file"

  run_start "$env_file" "$config_dir"

  expected=$'extraction:\n  enabled: true\n  extractors:\n    - tdai-memory'
  actual="$(extract_top_level_yaml_block extraction "$config_dir/config.yaml")"
  [[ "$actual" == "$expected" ]]
}

test_explicit_external_gateway_url_is_written
test_default_external_gateway_url_uses_published_proxy_port
test_generated_config_disables_skill_extraction_but_keeps_memory_writes

echo "start-proxy config: ok"
