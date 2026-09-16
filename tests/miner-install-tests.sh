#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/miner-install.sh"
TEST_ROOT="$(mktemp -d /tmp/miner-installer-fast.XXXXXX)" || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT
SCRIPT="$TEST_ROOT/miner-install.sh"
cp -- "$SOURCE_SCRIPT" "$SCRIPT" || exit 1
chmod 0755 "$SCRIPT" || exit 1
ADDRESS="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
PATH="$ROOT_DIR/tests/fixtures:$PATH"
export PATH
PASSED=0
FAILED=0

pass() {
  printf 'PASS: %s\n' "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILED=$((FAILED + 1))
}

expect_status() {
  local name="$1"
  local expected="$2"
  shift 2
  local output status

  output="$("$@" </dev/null 2>&1)"
  status=$?

  if [[ "$status" -eq "$expected" ]]; then
    pass "$name"
  else
    fail "$name (expected exit $expected, got $status)"
    printf '%s\n' "$output" | tail -n 12 >&2
  fi
}

expect_output() {
  local name="$1"
  local pattern="$2"
  shift 2
  local output status

  output="$("$@" </dev/null 2>&1)"
  status=$?

  if [[ "$status" -eq 0 ]] && printf '%s\n' "$output" | grep -Eq -- "$pattern"; then
    pass "$name"
  else
    fail "$name (exit $status, missing pattern: $pattern)"
    printf '%s\n' "$output" | tail -n 12 >&2
  fi
}

expect_output_without() {
  local name="$1"
  local required="$2"
  local forbidden="$3"
  shift 3
  local output status

  output="$("$@" </dev/null 2>&1)"
  status=$?

  if [[ "$status" -eq 0 ]] \
    && printf '%s\n' "$output" | grep -Eq -- "$required" \
    && ! printf '%s\n' "$output" | grep -Eq -- "$forbidden"; then
    pass "$name"
  else
    fail "$name (exit $status, required: $required, forbidden: $forbidden)"
    printf '%s\n' "$output" | tail -n 16 >&2
  fi
}

base64url() {
  base64 -w0 | tr '+/' '-_' | tr -d '='
}

main() {
  local bad_json_token valid_token token_header token_signature curl_log
  token_header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)"
  token_signature="$(printf 'A%.0s' {1..120})"
  valid_token="$token_header.$(printf '%s' '{"iss":"https://qubic.li/","aud":"https://qubic.li/","nbf":0,"exp":4102444800}' | base64url).$token_signature"
  bad_json_token="$(printf '%s' '{"alg":"none","typ":"JWT"}' | base64url).$(printf '%s' '{junk}' | base64url).$(printf 'A%.0s' {1..120})"

  if bash -n "$SCRIPT"; then
    pass "bash syntax"
  else
    fail "bash syntax"
  fi

  expect_status "--yes requires a pool" 1 \
    timeout 3 "$SCRIPT" --yes --dry-run --lang=en

  expect_status "missing option value is rejected" 1 \
    "$SCRIPT" jetski "$ADDRESS" audit --no-cpu --gpu --yes --dry-run --lang=en --gpu-version

  expect_status "unsupported pool is rejected" 1 \
    "$SCRIPT" unsupported --yes --dry-run --lang=en

  expect_status "unknown option is rejected" 1 \
    "$SCRIPT" qli 0 a.b.c --typo --yes --dry-run --lang=en

  expect_status "short JWT is rejected" 1 \
    "$SCRIPT" qli 0 a.b.c audit --yes --dry-run --lang=en

  expect_status "malformed JWT JSON is rejected" 1 \
    "$SCRIPT" qli 0 "$bad_json_token" audit --yes --dry-run --lang=en

  curl_log="$TEST_ROOT/curl.log"
  : > "$curl_log"
  expect_status "invalid QLI identity fails before release lookup" 1 \
    env CURL_FIXTURE_LOG="$curl_log" "$SCRIPT" qli 0 invalid audit \
      --yes --dry-run --lang=en
  if [[ ! -s "$curl_log" ]]; then
    pass "invalid QLI identity performs no network metadata lookup"
  else
    fail "invalid QLI identity queried release metadata"
  fi

  expect_status "invalid JetSki wallet is rejected" 1 \
    "$SCRIPT" jetski x audit --no-cpu --gpu --yes --dry-run --lang=en

  expect_status "invalid QLI boolean env is rejected" 1 \
    env QLI_CPU=maybe "$SCRIPT" qli 0 "$ADDRESS" audit --yes --dry-run --lang=en

  expect_status "cross-pool option is rejected" 1 \
    "$SCRIPT" qli 0 "$ADDRESS" audit --pplns --yes --dry-run --lang=en

  expect_status "too many positional arguments are rejected" 1 \
    "$SCRIPT" jetski "$ADDRESS" audit 0 extra --cpu --yes --dry-run --lang=en

  expect_status "interactive EOF exits instead of looping" 1 \
    timeout 5 "$SCRIPT" --dry-run --lang=en

  local confirmation_output confirmation_status
  confirmation_output="$(printf 'maybe\nn\n' | "$SCRIPT" qli 0 "$ADDRESS" audit \
    --cpu --no-gpu --dry-run --lang=en 2>&1)"
  confirmation_status=$?
  if [[ "$confirmation_status" -eq 0 \
    && "$confirmation_output" == *"Please enter y or n."* \
    && "$(printf '%s' "$confirmation_output" | grep -o 'Proceed with these actions?' | wc -l)" -eq 2 ]]; then
    pass "invalid confirmation is explained and prompted again"
  else
    fail "invalid confirmation should prompt again (exit $confirmation_status)"
  fi

  local safety_library safety_output safety_status
  safety_library="$TEST_ROOT/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$SCRIPT" > "$safety_library"
  safety_output="$(printf '\n' | bash -c '
    source "$1"
    LANG_CHOICE=en
    known_miners_running() { printf "%s\n" "mock miner"; }
    authorize_existing_miners
  ' _ "$safety_library" 2>&1)"
  safety_status=$?
  if [[ "$safety_status" -eq 1 && "$safety_output" == *"Stop the processes above before changing installation files? [y/N]:"* ]]; then
    pass "stopping an existing miner defaults to no"
  else
    fail "existing miner stop should require an explicit yes (exit $safety_status)"
  fi

  expect_status "removed XMR options are rejected" 1 \
    "$SCRIPT" qli 0 "$ADDRESS" audit --xmr-cpu --yes --dry-run --lang=en

  expect_status "conflicting CPU flags are rejected" 1 \
    "$SCRIPT" jetski "$ADDRESS" audit --cpu --no-cpu --gpu \
      --yes --dry-run --lang=en

  expect_status "conflicting actions are rejected" 1 \
    "$SCRIPT" --status --stop --yes --lang=en

  expect_status "status rejects install options" 1 \
    "$SCRIPT" qli --status --gpu --yes --lang=en

  expect_status "invalid negative QLI GPU card is rejected" 1 \
    "$SCRIPT" qli 0 "$ADDRESS" audit --no-cpu --gpu --gpu-cards -2 \
      --yes --dry-run --lang=en

  expect_status "Minerlab requires username" 1 \
    "$SCRIPT" minerlab --no-cpu --gpu \
      --yes --dry-run --lang=en

  expect_status "Minerlab rejects the removed accessToken argument" 1 \
    "$SCRIPT" minerlab audituser "$valid_token" 0 audit --no-cpu --gpu --yes --dry-run --lang=en

  expect_status "leading-zero fixed threads are rejected" 1 \
    "$SCRIPT" qli 08 "$ADDRESS" audit --cpu --no-gpu --yes --dry-run --lang=en

  expect_status "leading-zero ignored threads are rejected" 1 \
    "$SCRIPT" qli "$ADDRESS" audit --ignore-threads 08 --cpu --no-gpu --yes --dry-run --lang=en

  expect_output "QLI valid dry-run" '^Pool: QLI$' \
    "$SCRIPT" qli 0 "$ADDRESS" audit --no-cpu --gpu --yes --dry-run --lang=en

  expect_output "QLI 3.8.10 uses the audited pinned SHA-256" \
    '^Expected SHA-256: 08385d75f1ab4861edaf8462c3c7aa4a6343c1d068a9bf6ea94c2096eae62113$' \
    "$SCRIPT" qli 0 "$ADDRESS" audit --no-cpu --gpu --yes --dry-run --lang=en

  expect_output "dry-run result clearly distinguishes metadata reads from installation" \
    '^Status: dry-run only; nothing was installed or started$' \
    "$SCRIPT" qli 0 "$ADDRESS" audit --no-cpu --gpu --yes --dry-run --lang=en

  expect_output "THREADS environment value is preserved" \
    '^Threads: 7 \(fixed\)$' \
    env MINER_POOL=qli QLI_QUBIC_ADDRESS="$ADDRESS" QLI_CPU=1 QLI_GPU=0 \
      THREADS=7 "$SCRIPT" --yes --dry-run --lang=en

  expect_output_without "JetSki GPU-only omits CPU setup flag" \
    "Setup command: .*qubjetski-Client.* -gpu.* -pplns" \
    "Setup command: .*qubjetski-Client.* -cpu([[:space:]]|$)" \
    "$SCRIPT" jetski "$ADDRESS" audit --no-cpu --gpu --pplns \
      --yes --dry-run --lang=en

  expect_output "JetSki prefers the GitHub API asset digest" \
    '^Verification source: GitHub release digest$' \
    "$SCRIPT" jetski "$ADDRESS" audit --no-cpu --gpu --pplns \
      --yes --dry-run --lang=en

  expect_output "JetSki matches the digest to the exact neighboring asset URL" \
    '^Expected SHA-256: 807b264d60dcb6d02fdf128f195e4cf7e2cdfe5aa3e59906a109e8544cf16d2d$' \
    "$SCRIPT" jetski "$ADDRESS" audit --no-cpu --gpu --solo \
      --yes --dry-run --lang=en

  expect_output "Minerlab uses the QLAB.Z endpoint" \
    '^  - Pool address: wss://qu-pool\.minerlab\.io/ws/audituser$' \
    "$SCRIPT" minerlab audituser 0 audit --no-cpu --gpu --yes --dry-run --lang=en

  expect_output "Minerlab uses the official QLAB.Z archive hash" \
    '^Expected SHA-256: 018c32c1fef526ea3557c11786870e0ca6ea6a135c31f47b0dfff0360ed1f515$' \
    "$SCRIPT" minerlab audituser 0 audit --no-cpu --gpu --yes --dry-run --lang=en

  expect_output "Minerlab supports CPU-only QLAB.Z mode" \
    '^  - GPU miner: off$' \
    "$SCRIPT" minerlab audituser 2 audit --cpu --no-gpu --yes --dry-run --lang=en

  # shellcheck disable=SC2016
  expect_output "stdin execution prints a reusable GitHub stop command" \
    '^Stop command: curl .*raw\.githubusercontent\.com/XARKUR/qubic-mining/main/miner-install\.sh \| bash -s -- minerlab --stop --lang=en$' \
    bash -c 'cd "$1" && cat "$2" | bash -s -- minerlab audituser 0 audit --no-cpu --gpu --yes --dry-run --lang=en' \
      _ "$TEST_ROOT" "$SOURCE_SCRIPT"

  expect_status "Minerlab rejects malformed QLAB.Z hash metadata" 1 \
    env MINERLAB_HASH_FIXTURE_INVALID=1 "$SCRIPT" minerlab audituser 0 audit \
      --no-cpu --gpu --yes --dry-run --lang=en

  expect_status "Minerlab rejects a legacy payout-mode option" 1 \
    "$SCRIPT" minerlab audituser 0 audit --no-cpu --gpu --pps \
      --yes --dry-run --lang=en

  expect_output_without "dry-run language change does not claim it was saved" \
    '^Dry-run: language preference was not saved[.]$' \
    '^Language preference saved[.]$' \
    "$SCRIPT" --set-lang=en --dry-run

  printf '\nPassed: %d\nFailed: %d\n' "$PASSED" "$FAILED"
  [[ "$FAILED" -eq 0 ]]
}

main "$@"
