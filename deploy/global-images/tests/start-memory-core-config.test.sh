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

if [[ -n "${FAKE_DOCKER_LOG:-}" ]]; then
  printf '%q ' "$@" >> "$FAKE_DOCKER_LOG"
  printf '\n' >> "$FAKE_DOCKER_LOG"
fi

case "${1:-}" in
  network | run | rm | logs) exit 0 ;;
  ps)
    echo tdai-memory-core
    exit 0
    ;;
  inspect)
    if [[ "$*" == *State.Status* ]]; then
      echo running
    else
      echo none
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
      'MEMORY_CORE_IMAGE=test/memory-core:latest' \
      'MEMORY_CORE_PORT=1' \
      'MEMORY_CORE_VOLUME=test-memory-core-data'
    printf '%s\n' "$@"
  } > "$target"
}

run_start() {
  local env_file="$1"
  local output_file="$2"
  local docker_log="$3"

  PATH="$TMP_ROOT/bin:$PATH" \
    ENV_FILE="$env_file" \
    MEMORY_CORE_ADMIN_KEY_FILE="$TMP_ROOT/admin-key" \
    FAKE_DOCKER_LOG="$docker_log" \
    bash "$GLOBAL_IMAGES_DIR/start-memory-core.sh" > "$output_file" 2>&1
}

assert_file_equals() {
  local expected="$1"
  local actual="$2"
  if ! cmp -s "$expected" "$actual"; then
    echo "expected $actual to remain unchanged" >&2
    diff -u "$expected" "$actual" >&2 || true
    exit 1
  fi
}

test_existing_generated_config_is_reused() {
  local case_dir="$TMP_ROOT/existing"
  local config_dir="$case_dir/config"
  local config_file="$config_dir/tdai-gateway.yaml"
  local expected="$case_dir/expected.yaml"
  local env_file="$case_dir/.env"
  local output_file="$case_dir/output.log"
  local docker_log="$case_dir/docker.log"

  mkdir -p "$config_dir"
  printf 'sentinel: keep-existing-config\n' > "$config_file"
  cp "$config_file" "$expected"
  write_env "$env_file" \
    "MEMORY_CORE_CONFIG_DIR=$config_dir" \
    'MEMORY_LLM_BASE_URL=https://llm.example/v1' \
    'MEMORY_LLM_API_KEY=test-memory-key' \
    'MEMORY_LLM_MODEL=test-memory-model'

  run_start "$env_file" "$output_file" "$docker_log"

  assert_file_equals "$expected" "$config_file"
  grep -F "复用已有 gateway config → $config_file" "$output_file" >/dev/null
  grep -F "$config_file:/data/config/tdai-gateway.yaml:ro" "$docker_log" >/dev/null
  grep -F 'TDAI_LLM_BASE_URL=https://llm.example/v1' "$docker_log" >/dev/null
  grep -F 'TDAI_LLM_API_KEY=test-memory-key' "$docker_log" >/dev/null
  grep -F 'TDAI_LLM_MODEL=test-memory-model' "$docker_log" >/dev/null
}

test_explicit_config_is_mounted_without_generating_default() {
  local case_dir="$TMP_ROOT/explicit"
  local config_dir="$case_dir/generated"
  local config_file="$case_dir/custom.yaml"
  local env_file="$case_dir/.env"
  local output_file="$case_dir/output.log"
  local docker_log="$case_dir/docker.log"

  mkdir -p "$case_dir"
  printf 'sentinel: keep-explicit-config\n' > "$config_file"
  write_env "$env_file" \
    "MEMORY_CORE_CONFIG_DIR=$config_dir" \
    "MEMORY_CORE_CONFIG_FILE=$config_file"

  run_start "$env_file" "$output_file" "$docker_log"

  grep -Fx 'sentinel: keep-explicit-config' "$config_file" >/dev/null
  [[ ! -e "$config_dir/tdai-gateway.yaml" ]]
  grep -F "使用外部 gateway config → $config_file" "$output_file" >/dev/null
  grep -F "$config_file:/data/config/tdai-gateway.yaml:ro" "$docker_log" >/dev/null
  grep -F 'TDAI_GATEWAY_CONFIG=/data/config/tdai-gateway.yaml' "$docker_log" >/dev/null
}

test_missing_explicit_config_fails_before_docker_run() {
  local case_dir="$TMP_ROOT/missing"
  local missing_file="$case_dir/missing.yaml"
  local env_file="$case_dir/.env"
  local output_file="$case_dir/output.log"
  local docker_log="$case_dir/docker.log"

  mkdir -p "$case_dir"
  write_env "$env_file" "MEMORY_CORE_CONFIG_FILE=$missing_file"

  if run_start "$env_file" "$output_file" "$docker_log"; then
    echo "expected missing explicit config to fail" >&2
    exit 1
  fi

  grep -F "MEMORY_CORE_CONFIG_FILE 不存在或不是普通文件：$missing_file" "$output_file" >/dev/null
  if grep -Eq '^(rm|run) ' "$docker_log" 2>/dev/null; then
    echo "docker container mutation must not execute for a missing explicit config" >&2
    exit 1
  fi
}

test_first_run_generates_default_config() {
  local case_dir="$TMP_ROOT/first-run"
  local config_dir="$case_dir/config"
  local config_file="$config_dir/tdai-gateway.yaml"
  local env_file="$case_dir/.env"
  local output_file="$case_dir/output.log"
  local docker_log="$case_dir/docker.log"

  mkdir -p "$case_dir"
  write_env "$env_file" "MEMORY_CORE_CONFIG_DIR=$config_dir"

  run_start "$env_file" "$output_file" "$docker_log"

  grep -F 'deployMode: standalone' "$config_file" >/dev/null
  grep -F "初始化 gateway config → $config_file" "$output_file" >/dev/null
}

test_memory_max_body_bytes_is_forwarded_to_container() {
  local case_dir="$TMP_ROOT/max-body-bytes"
  local config_dir="$case_dir/config"
  local env_file="$case_dir/.env"
  local output_file="$case_dir/output.log"
  local docker_log="$case_dir/docker.log"

  mkdir -p "$case_dir"
  write_env "$env_file" \
    "MEMORY_CORE_CONFIG_DIR=$config_dir" \
    'MEMORY_MAX_BODY_BYTES=8388608'

  run_start "$env_file" "$output_file" "$docker_log"

  grep -F 'MEMORY_MAX_BODY_BYTES=8388608' "$docker_log" >/dev/null
}

test_existing_generated_config_is_reused
test_explicit_config_is_mounted_without_generating_default
test_missing_explicit_config_fails_before_docker_run
test_first_run_generates_default_config
test_memory_max_body_bytes_is_forwarded_to_container

echo "start-memory-core config lifecycle: ok"
