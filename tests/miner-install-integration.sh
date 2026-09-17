#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/miner-install.sh"
ADDRESS="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
PATH="$ROOT_DIR/tests/fixtures:$PATH"
export PATH
PASSED=0
FAILED=0
SKIPPED=0
SANDBOXES=()
PIDS=()
LAST_SANDBOX=""
QLI_URL="https://dl.qubic.li/downloads/qli-Client-3.8.10-Linux-x64.tar.gz"
QLI_ARCHIVE_SHA="08385d75f1ab4861edaf8462c3c7aa4a6343c1d068a9bf6ea94c2096eae62113"
JETSKI_URL="https://github.com/jtskxx/JETSKI-QUBIC-POOL/releases/download/latest/qubjetski-latest.tar.gz"
JETSKI_ARCHIVE_SHA="650588e0f852cd88bb17c896ae175dffe9418507f7e0839bea9879a8b067b593"

pass() {
  printf 'PASS: %s\n' "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAILED=$((FAILED + 1))
}

skip() {
  printf 'SKIP: %s\n' "$1"
  SKIPPED=$((SKIPPED + 1))
}

new_sandbox() {
  LAST_SANDBOX="$(mktemp -d /tmp/miner-installer-test.XXXXXX)"
  SANDBOXES+=("$LAST_SANDBOX")
  cp "$SCRIPT" "$LAST_SANDBOX/miner-install.sh"
  chmod +x "$LAST_SANDBOX/miner-install.sh"
}

write_manifest() {
  local dir="$1"
  local binary="$2"
  local url="$3"
  local archive_sha="$4"
  local binary_sha
  binary_sha="$(sha256sum "$dir/$binary" | awk '{print $1}')"
  cat > "$dir/.miner-install.version" <<EOF
url=$url
binary=$binary
archive_sha256=$archive_sha
binary_sha256=$binary_sha
installed_at=2026-07-31T00:00:00Z
EOF
  chmod 600 "$dir/.miner-install.version"
}

create_jetski_fixture() {
  local binary="$1"
  cat > "$binary" <<'EOF'
#!/usr/bin/env bash

set -u

base_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
cpu=false
gpu=false
threads=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -cpu) cpu=true ;;
    -gpu) gpu=true ;;
    -threads)
      shift
      threads="${1:-0}"
      ;;
  esac
  shift
done

cat > "$base_dir/appsettings.json" <<JSON
{
  "settings": {
    "cpu": {
      "enabled": $cpu,
      "threads": $threads
    },
    "gpu": {
      "enabled": $gpu
    }
  }
}
JSON
[[ "$cpu" == "true" ]] && printf 'cpu\n' > "$base_dir/workerConfig-CPU.lock"
[[ "$gpu" == "true" ]] && printf 'gpu\n' > "$base_dir/workerConfig-GPU.lock"
if [[ "${JETSKI_FIXTURE_FAIL:-0}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$binary"
}

cleanup() {
  local pid sandbox
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for sandbox in "${SANDBOXES[@]}"; do
    find "$sandbox" -depth -delete 2>/dev/null || true
  done
}

test_exact_process_stop() {
  local sandbox managed_pid unrelated_pid output
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/jetski"
  cp /bin/sleep "$sandbox/miners/jetski/qubjetski-Client"
  chmod +x "$sandbox/miners/jetski/qubjetski-Client"

  "$sandbox/miners/jetski/qubjetski-Client" 60 &
  managed_pid=$!
  /bin/sleep 60 &
  unrelated_pid=$!
  PIDS+=("$managed_pid" "$unrelated_pid")
  sleep 0.2

  output="$("$sandbox/miner-install.sh" jetski --status --yes --lang=en 2>&1)"
  if [[ "$output" != *"$managed_pid [JetSki]"* ]]; then
    fail "status identifies the exact project miner"
    return
  fi
  "$sandbox/miner-install.sh" jetski --stop --yes --lang=en >/dev/null 2>&1
  sleep 0.2
  if kill -0 "$managed_pid" 2>/dev/null; then
    fail "stop terminates the exact project miner"
    return
  fi
  if ! kill -0 "$unrelated_pid" 2>/dev/null; then
    fail "stop preserves an unrelated process"
    return
  fi
  pass "exact process status/stop preserves unrelated processes"
}

test_qli_interrupts_isolated_process_group() {
  local sandbox binary pid_file managed_pid child_pid output
  if ! command -v python3 >/dev/null 2>&1; then
    fail "QLI isolated process-group stop requires python3"
    return
  fi

  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/qli"
  binary="$sandbox/miners/qli/qli-Client"
  cp "$(readlink -f "$(command -v python3)")" "$binary"
  chmod +x "$binary"
  pid_file="$sandbox/qli-child.pid"

  setsid "$binary" -c '
import signal
import subprocess
import sys
import time

signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
child = subprocess.Popen(["/bin/sleep", "60"])
with open(sys.argv[1], "w", encoding="ascii") as handle:
    handle.write(str(child.pid))
time.sleep(60)
' "$pid_file" &
  managed_pid=$!
  PIDS+=("$managed_pid")

  for _ in {1..20}; do
    [[ -s "$pid_file" ]] && break
    sleep 0.05
  done
  if [[ ! -s "$pid_file" ]]; then
    fail "QLI process-group fixture starts"
    return
  fi
  child_pid="$(cat "$pid_file")"
  PIDS+=("$child_pid")

  output="$("$sandbox/miner-install.sh" qli --stop --yes --lang=en 2>&1)"
  sleep 0.2
  if kill -0 "$managed_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; then
    fail "QLI stop interrupts the isolated miner process group"
    return
  fi
  if [[ "$output" == *"trying TERM"* || "$output" == *"force-stopping"* ]]; then
    fail "QLI stop exits on the first Ctrl+C-compatible signal"
    return
  fi
  pass "QLI stop interrupts its isolated process group without escalation"
}

test_qli_stop_timeout_is_bounded() {
  local sandbox binary pid_file managed_pid output started_ns elapsed_ms
  if ! command -v python3 >/dev/null 2>&1; then
    fail "QLI bounded stop escalation requires python3"
    return
  fi

  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/qli"
  binary="$sandbox/miners/qli/qli-Client"
  cp "$(readlink -f "$(command -v python3)")" "$binary"
  chmod +x "$binary"
  pid_file="$sandbox/qli-unresponsive.pid"

  setsid -f "$binary" -c '
import os
import signal
import sys
import time

signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="ascii") as handle:
    handle.write(str(os.getpid()))
time.sleep(60)
' "$pid_file"
  for _ in {1..20}; do
    [[ -s "$pid_file" ]] && break
    sleep 0.05
  done
  if [[ ! -s "$pid_file" ]]; then
    fail "QLI bounded escalation fixture starts"
    return
  fi
  managed_pid="$(cat "$pid_file")"
  PIDS+=("$managed_pid")

  started_ns="$(date +%s%N)"
  output="$("$sandbox/miner-install.sh" qli --stop --yes --lang=en 2>&1)"
  elapsed_ms=$((($(date +%s%N) - started_ns) / 1000000))
  sleep 0.2

  if kill -0 "$managed_pid" 2>/dev/null; then
    fail "QLI bounded escalation force-stops an unresponsive miner"
    return
  fi
  if [[ "$output" != *"trying TERM"* || "$output" != *"force-stopping"* ]]; then
    fail "QLI bounded escalation reports each fallback"
    return
  fi
  if (( elapsed_ms > 4500 )); then
    fail "QLI bounded escalation completes in about 3 seconds (${elapsed_ms}ms)"
    return
  fi
  pass "QLI unresponsive stop escalates safely in ${elapsed_ms}ms"
}

test_start_failure_status() {
  local sandbox output status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/qli"
  cp /bin/false "$sandbox/miners/qli/qli-Client"
  chmod +x "$sandbox/miners/qli/qli-Client"
  write_manifest "$sandbox/miners/qli" "qli-Client" "$QLI_URL" "$QLI_ARCHIVE_SHA"

  output="$(timeout 45 "$sandbox/miner-install.sh" qli 0 "$ADDRESS" failcase \
    --cpu --no-gpu --yes --lang=en 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"Miner process failed to start"* ]]; then
    fail "immediate startup failure returns non-zero"
    return
  fi
  if [[ -f "$sandbox/miners/qli/.miner-install.state" ]]; then
    fail "failed startup does not leave a runtime state file"
    return
  fi
  pass "immediate startup failure returns non-zero without stale state"
}

test_dry_run_has_no_side_effects() {
  local sandbox
  new_sandbox
  sandbox="$LAST_SANDBOX"

  if ! timeout 45 "$sandbox/miner-install.sh" qli 0 "$ADDRESS" dryrun \
    --no-cpu --gpu --yes --dry-run --lang=en >/dev/null 2>&1; then
    fail "dry-run command completes"
    return
  fi
  if [[ -e "$sandbox/miners" || -e "$sandbox/downloads" \
    || -e "$sandbox/.miner-install.conf" ]]; then
    fail "dry-run creates no runtime files or directories"
    find "$sandbox" -mindepth 1 -maxdepth 3 -print >&2
    return
  fi
  pass "dry-run creates no runtime files or directories"
}

test_qli_config_json_and_permissions() {
  local sandbox config mode output config_valid=1 alias='rig"back\\slash'
  if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    fail "QLI JSON test requires jq or python3"
    return
  fi

  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/qli"
  cp /bin/true "$sandbox/miners/qli/qli-Client"
  chmod +x "$sandbox/miners/qli/qli-Client"
  write_manifest "$sandbox/miners/qli" "qli-Client" "$QLI_URL" "$QLI_ARCHIVE_SHA"

  if ! output="$(timeout 45 "$sandbox/miner-install.sh" qli 0 "$ADDRESS" "$alias" \
    --no-cpu --gpu --yes --no-start --lang=en 2>&1)"; then
    fail "QLI config generation with escaped alias"
    return
  fi
  config="$sandbox/miners/qli/appsettings.json"
  mode="$(stat -c '%a' "$config")"
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg alias "$alias" \
      '.ClientSettings.alias == $alias
        and .ClientSettings.qubicAddress != null
        and .ClientSettings.trainer.cpu == false
        and .ClientSettings.trainer.cpuThreads == 0' \
      "$config" >/dev/null || config_valid=0
  else
    python3 - "$config" "$alias" <<'PY' || config_valid=0
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)["ClientSettings"]
trainer = config["trainer"]
raise SystemExit(not (
    config["alias"] == sys.argv[2]
    and config["qubicAddress"] is not None
    and trainer["cpu"] is False
    and trainer["cpuThreads"] == 0
))
PY
  fi
  if [[ "$config_valid" -ne 1 ]]; then
    fail "QLI config is valid JSON with the selected values"
    cat "$config" >&2
    return
  fi
  if [[ "$mode" != "600" ]]; then
    fail "QLI config uses mode 600 (got $mode)"
    return
  fi
  if [[ "$output" != *"Status: installed and configured; not started as requested"* \
    || "$output" != *"Manual start:"* ]]; then
    fail "--no-start result explains that installation completed and how to start"
    return
  fi
  pass "QLI config escapes JSON and uses mode 600"
}

test_runtime_symlinks_are_rejected() {
  local sandbox target output status sentinel
  new_sandbox
  sandbox="$LAST_SANDBOX"
  target="$sandbox/redirect-target"
  mkdir -p "$target"
  sentinel="$target/sentinel"
  printf '%s\n' 'unchanged' > "$sentinel"
  ln -s redirect-target "$sandbox/miners"

  output="$(timeout 45 "$sandbox/miner-install.sh" qli 0 "$ADDRESS" symlink \
    --no-cpu --gpu --yes --no-start --lang=en 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"symlinked runtime directory"* ]]; then
    fail "symlinked runtime root is rejected"
    return
  fi
  if [[ "$(cat "$sentinel")" != "unchanged" || -e "$target/qli" ]]; then
    fail "symlinked runtime root is rejected before touching its target"
    return
  fi
  pass "symlinked runtime root is rejected before mutation"
}

test_install_lock_symlink_is_rejected() {
  local sandbox output status sentinel
  new_sandbox
  sandbox="$LAST_SANDBOX"
  sentinel="$sandbox/lock-target"
  printf '%s\n' 'unchanged' > "$sentinel"
  ln -s lock-target "$sandbox/.miner-install.lock"

  output="$(timeout 45 "$sandbox/miner-install.sh" qli 0 "$ADDRESS" locklink \
    --no-cpu --gpu --yes --no-start --lang=en 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"symlinked or non-regular install lock"* ]]; then
    fail "symlinked install lock is rejected"
    return
  fi
  if [[ "$(cat "$sentinel")" != "unchanged" ]]; then
    fail "symlinked install lock target remains unchanged"
    return
  fi
  pass "symlinked install lock is rejected before opening"
}

test_archive_safety_limits() {
  local sandbox library fixtures safe traversal symlink many large archive
  new_sandbox
  sandbox="$LAST_SANDBOX"
  library="$sandbox/library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"
  fixtures="$sandbox/archive-fixtures"
  mkdir -p "$fixtures/safe"
  printf '%s\n' fixture > "$fixtures/safe/miner"
  safe="$fixtures/safe.tar.gz"
  traversal="$fixtures/traversal.tar.gz"
  symlink="$fixtures/symlink.tar.gz"
  many="$fixtures/many.tar.gz"
  large="$fixtures/large.tar.gz"
  tar -czf "$safe" -C "$fixtures/safe" miner
  python3 - "$traversal" "$symlink" "$many" <<'PY'
import io
import sys
import tarfile

traversal, symlink, many = sys.argv[1:]
with tarfile.open(traversal, "w:gz") as archive:
    item = tarfile.TarInfo("../escape")
    item.size = 1
    archive.addfile(item, io.BytesIO(b"x"))
with tarfile.open(symlink, "w:gz") as archive:
    item = tarfile.TarInfo("miner")
    item.type = tarfile.SYMTYPE
    item.linkname = "/bin/true"
    archive.addfile(item)
with tarfile.open(many, "w:gz") as archive:
    for index in range(257):
        archive.addfile(tarfile.TarInfo(f"entry-{index}"))
PY
  mkdir -p "$fixtures/large"
  python3 - "$fixtures/large/miner" <<'PY'
import os
import sys
with open(sys.argv[1], "wb") as handle:
    handle.truncate(536870913)
PY
  tar --sparse -czf "$large" -C "$fixtures/large" miner

  if ! bash -c 'source "$1"; archive_is_safe "$2"' _ "$library" "$safe"; then
    fail "ordinary archive passes safety validation"
    return
  fi
  for archive in "$traversal" "$symlink" "$many" "$large"; do
    if bash -c 'source "$1"; archive_is_safe "$2"' _ "$library" "$archive"; then
      fail "unsafe or oversized archive is rejected: $(basename "$archive")"
      return
    fi
  done
  pass "archive safety rejects traversal, links, excess entries, and oversized files"
}

test_jetski_gpu_only_config() {
  local sandbox config
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/jetski"
  create_jetski_fixture "$sandbox/miners/jetski/qubjetski-Client"
  write_manifest "$sandbox/miners/jetski" "qubjetski-Client" \
    "$JETSKI_URL" "$JETSKI_ARCHIVE_SHA"

  if ! timeout 45 "$sandbox/miner-install.sh" jetski "$ADDRESS" gpuonly \
    --no-cpu --gpu --pplns --yes --no-start --lang=en >/dev/null 2>&1; then
    fail "JetSki GPU-only no-start setup"
    return
  fi
  config="$sandbox/miners/jetski/appsettings.json"
  if ! awk '
    /"cpu"[[:space:]]*:/ { section = "cpu" }
    /"gpu"[[:space:]]*:/ { section = "gpu" }
    section == "cpu" && /"enabled"[[:space:]]*:[[:space:]]*false/ { cpu = 1 }
    section == "cpu" && /"threads"[[:space:]]*:[[:space:]]*0/ { threads = 1 }
    section == "gpu" && /"enabled"[[:space:]]*:[[:space:]]*true/ { gpu = 1 }
    END { exit !(cpu && threads && gpu) }
  ' "$config"; then
    fail "JetSki GPU-only config explicitly disables CPU"
    cat "$config" >&2
    return
  fi
  pass "JetSki GPU-only config explicitly disables CPU"
}

test_yes_refuses_duplicate_miner() {
  local sandbox managed_pid output status count=0 pid actual expected
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/qli"
  cp /bin/sleep "$sandbox/miners/qli/qli-Client"
  chmod +x "$sandbox/miners/qli/qli-Client"
  write_manifest "$sandbox/miners/qli" "qli-Client" "$QLI_URL" "$QLI_ARCHIVE_SHA"

  "$sandbox/miners/qli/qli-Client" 60 &
  managed_pid=$!
  PIDS+=("$managed_pid")
  sleep 0.2

  output="$(timeout 45 "$sandbox/miner-install.sh" qli 0 "$ADDRESS" duplicate \
    --cpu --no-gpu --yes --lang=en 2>&1)"
  status=$?
  expected="$(readlink -f "$sandbox/miners/qli/qli-Client")"
  while IFS= read -r pid; do
    actual="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    [[ "$actual" == "$expected" ]] && count=$((count + 1))
  done < <(pgrep -f qli-Client 2>/dev/null || true)

  if [[ "$status" -eq 0 || "$output" != *"will not silently start a second miner"* ]]; then
    fail "--yes refuses a duplicate miner with a clear error"
    return
  fi
  if [[ "$count" -ne 1 || ! -d "/proc/$managed_pid" ]]; then
    fail "--yes leaves exactly the original miner running (count $count)"
    return
  fi
  pass "--yes refuses to start a second miner"
}

test_jetski_setup_failure_preserves_active_config() {
  local sandbox config before output status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/jetski"
  create_jetski_fixture "$sandbox/miners/jetski/qubjetski-Client"
  write_manifest "$sandbox/miners/jetski" "qubjetski-Client" \
    "$JETSKI_URL" "$JETSKI_ARCHIVE_SHA"
  config="$sandbox/miners/jetski/appsettings.json"
  printf '%s\n' '{"existing":"keep-me"}' > "$config"
  printf '%s\n' 'old-lock' > "$sandbox/miners/jetski/workerConfig-GPU.lock"
  chmod 600 "$config" "$sandbox/miners/jetski/workerConfig-GPU.lock"
  before="$(sha256sum "$config" | awk '{print $1}')"

  output="$(JETSKI_FIXTURE_FAIL=1 timeout 45 "$sandbox/miner-install.sh" \
    jetski "$ADDRESS" rollback --no-cpu --gpu --pplns \
    --yes --no-start --lang=en 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"JetSki configuration generation failed"* ]]; then
    fail "JetSki setup failure returns non-zero"
    return
  fi
  if [[ ! -f "$config" || "$(sha256sum "$config" | awk '{print $1}')" != "$before" ]]; then
    fail "JetSki setup failure preserves the active config"
    return
  fi
  if [[ "$(cat "$sandbox/miners/jetski/workerConfig-GPU.lock")" != "old-lock" ]]; then
    fail "JetSki setup failure preserves active worker locks"
    return
  fi
  if find "$sandbox/miners/jetski" -maxdepth 1 -type d -name '.jetski-stage.*' | grep -q .; then
    fail "JetSki setup failure removes its staging directory"
    return
  fi
  pass "JetSki setup failure preserves active config and locks"
}

test_unknown_cache_requires_sha_sidecar() {
  local sandbox archive library url status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/cache/payload"
  printf '%s\n' 'fixture' > "$sandbox/cache/payload/file.txt"
  archive="$sandbox/cache/test.tar.gz"
  tar -czf "$archive" -C "$sandbox/cache/payload" file.txt
  url="https://github.com/example/project/releases/download/v1/test.tar.gz"
  printf '%s\n' "$url" > "$archive.url"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  bash -c 'source "$1"; archive_integrity_ok "$2" "$3"' \
    _ "$library" "$url" "$archive" >/dev/null 2>&1
  status=$?
  if [[ "$status" -eq 0 ]]; then
    fail "unknown cached archive without .sha256 is rejected"
    return
  fi
  pass "unknown cached archive requires URL and SHA sidecars"
}

test_official_download_without_checksum_records_local_digest() {
  local sandbox source_archive output library url output_text status expected recorded
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/source/payload"
  printf '%s\n' 'future official fixture' > "$sandbox/source/payload/qli-Client"
  source_archive="$sandbox/source/future.tar.gz"
  tar -czf "$source_archive" -C "$sandbox/source/payload" qli-Client
  output="$sandbox/downloads/qli-Client-9.9.9-Linux-x64.tar.gz"
  url="https://dl.qubic.li/downloads/qli-Client-9.9.9-Linux-x64.tar.gz"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  output_text="$(FAKE_ARCHIVE="$source_archive" bash -c '
    source "$1"
    LANG_CHOICE=en
    DRY_RUN=0
    AUTO_YES=1
    FORCE_DOWNLOAD=0
    DOWNLOAD_TRUST_URL=""
    DOWNLOAD_TRUST_SHA256=""
    DOWNLOAD_TRUST_SOURCE=""
    download_with_retries() { cp "$FAKE_ARCHIVE" "$2"; }
    download_archive "$2" "$3"
  ' _ "$library" "$url" "$output" 2>&1)"
  status=$?
  if [[ "$status" -ne 0 || "$output_text" != *"official pool HTTPS allowlist"* ]]; then
    fail "official download without checksum is allowed and disclosed"
    return
  fi
  if [[ ! -f "$output" || ! -f "$output.sha256" || ! -f "$output.url" ]]; then
    fail "official download without checksum records cache metadata"
    return
  fi
  expected="$(sha256sum "$source_archive" | awk '{print $1}')"
  recorded="$(awk 'NR == 1 {print $1}' "$output.sha256")"
  if [[ "$recorded" != "$expected" || "$(cat "$output.url")" != "$url" ]]; then
    fail "official download records its exact URL and local SHA"
    return
  fi
  if [[ "$(stat -c %a "$output.sha256")" != "600" || "$(stat -c %a "$output.url")" != "600" ]]; then
    fail "official download protects local integrity metadata"
    return
  fi
  pass "official download without checksum records a local integrity baseline"
}

test_download_verification_requires_confirmation() {
  local sandbox source_archive output library url digest output_text status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/source/payload"
  printf '%s\n' 'confirmed miner fixture' > "$sandbox/source/payload/qli-Client"
  source_archive="$sandbox/source/confirmed.tar.gz"
  tar -czf "$source_archive" -C "$sandbox/source/payload" qli-Client
  digest="$(sha256sum "$source_archive" | awk '{print $1}')"
  output="$sandbox/downloads/qli-Client-9.9.7-Linux-x64.tar.gz"
  url="https://dl.qubic.li/downloads/qli-Client-9.9.7-Linux-x64.tar.gz"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  output_text="$(printf 'n\n' | FAKE_ARCHIVE="$source_archive" bash -c '
    source "$1"
    LANG_CHOICE=en
    DRY_RUN=0
    DOWNLOAD_TRUST_URL="$2"
    DOWNLOAD_TRUST_SHA256="$4"
    DOWNLOAD_TRUST_SOURCE="fixture upstream digest"
    download_with_retries() { cp "$FAKE_ARCHIVE" "$2"; }
    download_archive "$2" "$3"
  ' _ "$library" "$url" "$output" "$digest" 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || -e "$output" || -e "$output.sha256" \
    || "$output_text" != *"Miner download source: $url"* \
    || "$output_text" != *"Publisher reference: https://github.com/qubic-li/client"* \
    || "$output_text" != *"Downloaded file SHA-256: $digest"* \
    || "$output_text" != *"Expected SHA-256: $digest"* \
    || "$output_text" != *"Digest source: fixture upstream digest"* \
    || "$output_text" != *"Comparison: MATCH"* ]]; then
    fail "download shows provenance and matching hashes before confirmation"
    return
  fi

  output_text="$(printf 'y\n' | FAKE_ARCHIVE="$source_archive" bash -c '
    source "$1"
    LANG_CHOICE=en
    DRY_RUN=0
    DOWNLOAD_TRUST_URL="$2"
    DOWNLOAD_TRUST_SHA256="$4"
    DOWNLOAD_TRUST_SOURCE="fixture upstream digest"
    download_with_retries() { cp "$FAKE_ARCHIVE" "$2"; }
    download_archive "$2" "$3"
  ' _ "$library" "$url" "$output" "$digest" 2>&1)"
  status=$?
  if [[ "$status" -ne 0 || ! -f "$output" || ! -f "$output.sha256" \
    || "$(awk 'NR == 1 {print $1}' "$output.sha256")" != "$digest" ]]; then
    fail "confirmed verified download is cached for installation"
    return
  fi
  pass "download provenance and hash match require explicit confirmation"
}

test_nonofficial_github_release_is_rejected() {
  local sandbox library output status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  output="$(bash -c '
    source "$1"
    LANG_CHOICE=en
    validate_download_url "https://github.com/example/project/releases/download/v1/miner.tar.gz"
  ' _ "$library" 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"outside the allowlist"* ]]; then
    fail "nonofficial GitHub release URL is rejected"
    return
  fi
  pass "nonofficial GitHub release URL remains outside the allowlist"
}

test_published_hash_mismatch_is_rejected() {
  local sandbox source_archive output library url output_text status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/source/payload"
  printf '%s\n' 'mismatch fixture' > "$sandbox/source/payload/qli-Client"
  source_archive="$sandbox/source/mismatch.tar.gz"
  tar -czf "$source_archive" -C "$sandbox/source/payload" qli-Client
  output="$sandbox/downloads/qli-Client-9.9.8-Linux-x64.tar.gz"
  url="https://dl.qubic.li/downloads/qli-Client-9.9.8-Linux-x64.tar.gz"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  output_text="$(FAKE_ARCHIVE="$source_archive" bash -c '
    source "$1"
    LANG_CHOICE=en
    DRY_RUN=0
    FORCE_DOWNLOAD=0
    DOWNLOAD_TRUST_URL="$2"
    DOWNLOAD_TRUST_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
    DOWNLOAD_TRUST_SOURCE="test published digest"
    download_with_retries() { cp "$FAKE_ARCHIVE" "$2"; }
    download_archive "$2" "$3"
  ' _ "$library" "$url" "$output" 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output_text" != *"does not match the trusted upstream"* || -e "$output" ]]; then
    fail "published checksum mismatch is rejected"
    return
  fi
  pass "published checksum mismatch still blocks installation"
}

test_saved_language_applies_to_parse_errors() {
  local sandbox output status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  printf '%s\n' 'LANG_CHOICE=zh' > "$sandbox/.miner-install.conf"
  chmod 600 "$sandbox/.miner-install.conf"

  output="$("$sandbox/miner-install.sh" --unknown-option 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"未知选项"* ]]; then
    fail "saved language applies to argument parsing errors"
    return
  fi
  pass "saved language applies before argument parsing"
}

test_binary_hash_mismatch_is_rejected() {
  local sandbox output status manifest
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/qli"
  cp /bin/true "$sandbox/miners/qli/qli-Client"
  chmod +x "$sandbox/miners/qli/qli-Client"
  write_manifest "$sandbox/miners/qli" "qli-Client" "$QLI_URL" "$QLI_ARCHIVE_SHA"
  manifest="$sandbox/miners/qli/.miner-install.version"
  sed -i 's/^binary_sha256=.*/binary_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$manifest"

  output="$(timeout 45 "$sandbox/miner-install.sh" qli 0 "$ADDRESS" tampered \
    --no-cpu --gpu --yes --no-start --lang=en 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"does not match its manifest"* ]]; then
    fail "binary SHA mismatch is rejected"
    return
  fi
  pass "installed binary SHA is verified before reuse"
}

test_critical_startup_log_stops_miner() {
  local sandbox source binary output status
  if ! command -v cc >/dev/null 2>&1; then
    fail "critical startup-log fixture requires a C compiler"
    return
  fi
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/qli"
  source="$sandbox/critical-miner.c"
  binary="$sandbox/miners/qli/qli-Client"
  cat > "$source" <<'EOF'
#include <stdio.h>
#include <unistd.h>

int main(void) {
  puts("A deterministic startup integrity check FAILED on this box.");
  fflush(stdout);
  sleep(60);
  return 0;
}
EOF
  cc -O2 -o "$binary" "$source"
  chmod +x "$binary"
  write_manifest "$sandbox/miners/qli" "qli-Client" "$QLI_URL" "$QLI_ARCHIVE_SHA"

  output="$(timeout 45 "$sandbox/miner-install.sh" qli 0 "$ADDRESS" unhealthy \
    --cpu --no-gpu --yes --lang=en 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"a critical log error was found"* ]]; then
    fail "critical startup log returns non-zero"
    return
  fi
  if [[ -n "$("$sandbox/miner-install.sh" qli --status --yes --lang=en 2>&1 \
    | grep 'qli-Client' || true)" ]]; then
    fail "critical startup log stops the failed miner"
    return
  fi
  pass "critical startup log fails and stops the miner"
}

test_root_install_guard() {
  local sandbox library output status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  output="$(bash -c '
    source "$1"
    running_as_root() { return 0; }
    LANG_CHOICE=en
    ACTION_MODE=install
    DRY_RUN=0
    environment_check
  ' _ "$library" 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"Refusing to install as root"* ]]; then
    fail "root install is rejected before download or execution"
    return
  fi
  pass "root install guard fails closed"
}

test_stop_failure_propagates_nonzero() {
  local sandbox library output status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  output="$(bash -c '
    source "$1"
    LANG_CHOICE=en
    AUTO_YES=1
    pool_process_lines() { printf "%s\n" "123 [QLI] fixture"; }
    stop_pool_processes() { return 1; }
    legacy_qlab_active() { return 1; }
    stop_pool qli
  ' _ "$library" 2>&1)"
  status=$?
  if [[ "$status" -eq 0 || "$output" != *"could not be confirmed stopped"* ]]; then
    fail "stop failure returns non-zero"
    return
  fi
  pass "stop failure propagates a non-zero status"
}

test_jetski_same_url_hash_change_is_detected() {
  local sandbox library binary manifest output status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/jetski"
  binary="$sandbox/miners/jetski/qubjetski-Client"
  cp /bin/true "$binary"
  chmod +x "$binary"
  write_manifest "$sandbox/miners/jetski" "qubjetski-Client" \
    "$JETSKI_URL" "0000000000000000000000000000000000000000000000000000000000000000"
  manifest="$sandbox/miners/jetski/.miner-install.version"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  output="$(bash -c '
    source "$1"
    LANG_CHOICE=en
    AUTO_YES=1
    DOWNLOAD_TRUST_URL="$2"
    DOWNLOAD_TRUST_SHA256="$3"
    DOWNLOAD_TRUST_SOURCE="test"
    should_install_binary "$2" "$4" "$5"
  ' _ "$library" "$JETSKI_URL" "$JETSKI_ARCHIVE_SHA" "$binary" "$manifest" 2>&1)"
  status=$?
  if [[ "$status" -ne 1 || "$output" != *"new release asset is available"* ]]; then
    fail "JetSki same-URL remote hash change is detected"
    return
  fi
  pass "JetSki update detection compares the trusted hash, not only the URL"
}

test_legacy_manifest_migrates_from_trusted_cache() {
  local sandbox library binary archive url archive_sha binary_sha output status
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/qli" "$sandbox/downloads/package"
  binary="$sandbox/miners/qli/qli-Client"
  cp /bin/true "$binary"
  cp /bin/true "$sandbox/downloads/package/qli-Client"
  chmod +x "$binary" "$sandbox/downloads/package/qli-Client"
  archive="$sandbox/downloads/test-miner.tar.gz"
  tar -czf "$archive" -C "$sandbox/downloads/package" qli-Client
  archive_sha="$(sha256sum "$archive" | awk '{print $1}')"
  binary_sha="$(sha256sum "$binary" | awk '{print $1}')"
  url="https://github.com/example/project/releases/download/v1/test-miner.tar.gz"
  cat > "$sandbox/miners/qli/.miner-install.version" <<EOF
url=$url
binary=qli-Client
archive_sha256=$archive_sha
installed_at=2026-07-31T00:00:00Z
EOF
  chmod 600 "$sandbox/miners/qli/.miner-install.version"
  library="$sandbox/miner-install-library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"

  output="$(bash -c '
    source "$1"
    LANG_CHOICE=en
    AUTO_YES=1
    DOWNLOAD_TRUST_URL="$2"
    DOWNLOAD_TRUST_SHA256="$3"
    DOWNLOAD_TRUST_SOURCE="test"
    should_install_binary "$2" "$4" "$5"
  ' _ "$library" "$url" "$archive_sha" "$binary" \
    "$sandbox/miners/qli/.miner-install.version" 2>&1)"
  status=$?
  if [[ "$status" -ne 1 || "$output" != *"Safely migrated the legacy manifest"* ]]; then
    fail "legacy manifest migrates only after trusted archive verification"
    return
  fi
  if [[ "$(sed -n 's/^binary_sha256=//p' "$sandbox/miners/qli/.miner-install.version")" != "$binary_sha" ]]; then
    fail "legacy manifest records the verified installed binary SHA"
    return
  fi
  pass "legacy manifest migrates from a trusted matching cache"
}


test_jetski_legacy_mode_packages_migrate() {
  local sandbox library binary old_url
  local pplns_url="https://github.com/jtskxx/JETSKI-QUBIC-POOL/releases/download/latest/qubjetski.PPLNS-latest.tar.gz"
  local versioned_url="https://github.com/jtskxx/JETSKI-QUBIC-POOL/releases/download/latest/qubjetski-Linux-v4.3.tar.gz"
  new_sandbox
  sandbox="$LAST_SANDBOX"
  mkdir -p "$sandbox/miners/jetski"
  binary="$sandbox/miners/jetski/qubjetski-Client"
  cp /bin/true "$binary"
  library="$sandbox/library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"
  for old_url in "$pplns_url" "$versioned_url"; do
    write_manifest "$sandbox/miners/jetski" qubjetski-Client "$old_url" "$JETSKI_ARCHIVE_SHA"
    if ! bash -c '
      source "$1"
      LANG_CHOICE=en
      AUTO_YES=1
      should_install_binary "$2" "$3" "$4"
    ' _ "$library" "$JETSKI_URL" "$binary" "$sandbox/miners/jetski/.miner-install.version" >/dev/null 2>&1; then
      fail "JetSki must replace legacy PPLNS or versioned packages"
      return
    fi
  done
  pass "JetSki migrates legacy PPLNS and versioned clients to the stable package"
}

test_stop_failure_preserves_install_files() {
  local sandbox library pool no_start
  new_sandbox
  sandbox="$LAST_SANDBOX"
  library="$sandbox/library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"
  for pool in qli jetski minerlab; do
    for no_start in 0 1; do
      if ! bash -c '
        source "$1"
        LANG_CHOICE=en
        POOL="$2"
        NO_START="$3"
        STOP_EXISTING=1
        INSTALL_DIR="$MINERS_DIR/$POOL"
        CONFIG_PATH="$INSTALL_DIR/appsettings.json"
        CONFIG_CONTENT="replacement"
        DOWNLOAD_URLS=(https://dl.qubic.li/downloads/qli-Client-3.7.0-Linux-x64.tar.gz)
        mkdir -p "$INSTALL_DIR"
        printf "original\n" > "$CONFIG_PATH"
        known_miners_running() { printf "123 [fixture]\n"; }
        stop_pool_processes() { return 1; }
        legacy_qlab_active() { return 1; }
        install_binary_from_archive() { touch "$BASE_DIR/mutated"; }
        install_minerlab_assets() { touch "$BASE_DIR/mutated"; }
        prepare_jetski_runtime() { touch "$BASE_DIR/mutated"; }
        if execute_pool; then exit 1; fi
        [[ "$(cat "$CONFIG_PATH")" == original && ! -e "$BASE_DIR/mutated" && ! -e "$CONFIG_PATH.previous" ]]
      ' _ "$library" "$pool" "$no_start" >/dev/null 2>&1; then
        fail "stop failure preserves $pool files (no-start=$no_start)"
        return
      fi
    done
  done
  pass "stop failure prevents file changes for every pool, including no-start"
}

test_minerlab_qlab_config() {
  local sandbox library config
  new_sandbox
  sandbox="$LAST_SANDBOX"
  library="$sandbox/library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"
  if ! config="$(bash -c '
    source "$1"
    LANG_CHOICE=en
    AUTO_YES=1
    PARAM_MODE=1
    POOL=minerlab
    FLAG_CPU=1
    FLAG_GPU=1
    POOL_ARGS=(audituser 2 rig01)
    prepare_minerlab
    printf "%s\n" "$CONFIG_CONTENT"
  ' _ "$library" 2>/dev/null)"; then
    fail "Minerlab QLAB.Z config preparation succeeds"
    return
  fi
  if ! printf '%s\n' "$config" | python3 -c '
import json, sys
settings = json.load(sys.stdin)
assert settings["pool"] == {
    "url": "wss://qu-pool.minerlab.io/ws/audituser",
    "wallet": "audituser",
    "alias": "rig01",
    "pps": False,
}
assert settings["miner"]["cpu"] == {"enabled": True, "version": "auto", "threads": 2}
assert settings["miner"]["gpu"] == {"enabled": True, "version": "CUDA", "cards": "all"}
assert settings["api"] == {"bind": "127.0.0.1:17899"}
'; then
    fail "Minerlab QLAB.Z config matches the official schema"
    return
  fi
  pass "Minerlab QLAB.Z config matches the official schema"
}

test_legacy_minerlab_binary_is_detected() {
  local sandbox library legacy_pid detected
  new_sandbox
  sandbox="$LAST_SANDBOX"
  library="$sandbox/library.sh"
  sed '/^main "\$@"$/d' "$sandbox/miner-install.sh" > "$library"
  mkdir -p "$sandbox/miners/minerlab"
  cp /bin/sleep "$sandbox/miners/minerlab/qli-Client"
  chmod +x "$sandbox/miners/minerlab/qli-Client"
  "$sandbox/miners/minerlab/qli-Client" 60 &
  legacy_pid=$!
  PIDS+=("$legacy_pid")
  detected="$(bash -c 'source "$1"; pool_pids minerlab' _ "$library")"
  if [[ "$detected" != *"$legacy_pid"* ]]; then
    fail "legacy Minerlab QLI process remains detectable during migration"
    return
  fi
  pass "legacy Minerlab QLI process remains detectable during migration"
}

main() {
  trap cleanup EXIT
  test_jetski_legacy_mode_packages_migrate
  test_stop_failure_preserves_install_files
  test_minerlab_qlab_config
  test_legacy_minerlab_binary_is_detected
  test_exact_process_stop
  test_qli_interrupts_isolated_process_group
  test_qli_stop_timeout_is_bounded
  test_start_failure_status
  test_dry_run_has_no_side_effects
  test_qli_config_json_and_permissions
  test_runtime_symlinks_are_rejected
  test_install_lock_symlink_is_rejected
  test_archive_safety_limits
  test_jetski_gpu_only_config
  test_yes_refuses_duplicate_miner
  test_jetski_setup_failure_preserves_active_config
  test_unknown_cache_requires_sha_sidecar
  test_official_download_without_checksum_records_local_digest
  test_download_verification_requires_confirmation
  test_nonofficial_github_release_is_rejected
  test_published_hash_mismatch_is_rejected
  test_saved_language_applies_to_parse_errors
  test_binary_hash_mismatch_is_rejected
  test_critical_startup_log_stops_miner
  test_root_install_guard
  test_stop_failure_propagates_nonzero
  test_jetski_same_url_hash_change_is_detected
  test_legacy_manifest_migrates_from_trusted_cache
  printf '\nPassed: %d\nFailed: %d\nSkipped: %d\n' "$PASSED" "$FAILED" "$SKIPPED"
  [[ "$FAILED" -eq 0 ]]
}

main "$@"
