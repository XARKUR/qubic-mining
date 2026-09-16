#!/usr/bin/env bash

set -u
umask 077

REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/XARKUR/qubic-mining/main/miner-install.sh"
STREAMED_ENTRYPOINT=0
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  BASE_DIR="$(pwd -P)"
  STREAMED_ENTRYPOINT=1
fi
MINERS_DIR="$BASE_DIR/miners"
DOWNLOADS_DIR="$BASE_DIR/downloads"
LANG_CONFIG_FILE="$BASE_DIR/.miner-install.conf"
INPUT_THREADS="${THREADS:-}"

LANG_CHOICE=""
CHANGE_LANG=0
SET_LANG_VALUE=""
DRY_RUN=0
AUTO_YES=0
NO_START=0
STOP_EXISTING=0
FORCE_DOWNLOAD=0
HELP_REQUESTED=0
ACTION_MODE="install"
START_ATTEMPTED=0

POOL=""
POOL_ARGS=()
PARAM_MODE=0

FLAG_CPU=""
FLAG_GPU=""
FLAG_PPLNS=0
FLAG_PPS=""
FLAG_AUTO_UPDATE=""
FLAG_GPU_VERSION=""
FLAG_GPU_CARDS=""
FLAG_IGNORE_THREADS=""
FLAG_USE_AVX2=0
JETSKI_ARCHIVE_NAME="qubjetski.PPLNS-latest.tar.gz"
MAX_ARCHIVE_ENTRIES=256
MAX_ARCHIVE_MEMBER_BYTES=536870912
MAX_ARCHIVE_TOTAL_BYTES=1073741824

POOL_NAME=""
PROFILE_FAMILY=""
PROFILE_MODE=""
INSTALL_DIR=""
CONFIG_PATH=""
LOG_PATH=""
START_CMD=""
SETUP_CMD=""
STOP_CMD=""
START_ARGS=()
SETUP_ARGS=()
STARTED_PID=""
STATE_PATH=""
LOCK_PATH="$BASE_DIR/.miner-install.lock"
MINER_BINARY_PATH=""
MINERLAB_RELEASE_VERSION=""
MINERLAB_BINARY_SHA256=""
DOWNLOAD_TRUST_URL=""
DOWNLOAD_TRUST_SHA256=""
DOWNLOAD_TRUST_SOURCE=""
WORKER_NAME=""
THREAD_MODE=""
THREADS=""
START_LOG_PATH=""
START_LOG_OFFSET=0
STARTUP_STATUS=""
DOWNLOAD_URLS=()
ACTION_SUMMARY=()
RISK_SUMMARY=()
CONFIG_CONTENT=""
SEEN_OPTIONS=()

GREEN="" YELLOW="" BLUE="" HEADING="" NC=""
PROMPT_COLOR="" ERROR_COLOR="" STDERR_NC=""
if [[ -z "${NO_COLOR+x}" && "${TERM:-dumb}" != "dumb" ]]; then
  if [[ -t 1 ]]; then
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[36m'
    HEADING=$'\033[1;36m'
    NC=$'\033[0m'
  fi
  if [[ -t 2 ]]; then
    PROMPT_COLOR=$'\033[1;36m'
    ERROR_COLOR=$'\033[31m'
    STDERR_NC=$'\033[0m'
  fi
fi

usage() {
  if is_zh; then
    cat <<'EOF'
用法：
  ./miner-install.sh [--lang=zh|en] [--dry-run] [--yes]
  ./miner-install.sh <矿池> [矿池参数...] [选项]

矿池：
  qli       ./miner-install.sh qli <线程数> <accessToken|qubicAddress> [矿工名]
  jetski    ./miner-install.sh jetski <wallet> [workername] [CPU线程数] [--cpu] [--gpu] [--pplns|--solo]
  minerlab  ./miner-install.sh minerlab <username> [CPU线程数] [矿工名]

选项：
  --lang=zh|en
  --change-lang       重新选择并保存语言
  --set-lang=zh|en    直接保存语言偏好
  --dry-run           只预演，不下载、不写文件、不启动
  --yes               非交互确认，必填参数需通过命令行或环境变量提供
  --no-start          只安装/写配置，不启动 miner
  --status            查看当前 miner 状态
  --monitor           查看当前 miner 日志
  --stop              停止当前或指定矿池 miner
  --stop-existing     改写安装文件前停止已知 miner 进程
  --force-download    不复用已有下载/二进制，强制重新下载
  --ignore-threads N  使用 nproc-N 个线程
  --use-avx2          QLI/Minerlab 设置 CPU version=AVX2
  --cpu | --no-cpu
  --gpu | --no-gpu
  --gpu-version CUDA|AMD
  --gpu-cards "-1,-1,0"
  --pps               QLI 使用 PPS 模式
  --solo              QLI 使用 Solo；JetSki 显式使用 SOLO
  --auto-update       QLI 写入 autoUpdate=true
  --no-auto-update    QLI 写入 autoUpdate=false
  --pplns             JetSki 使用 PPLNS 模式（默认）
EOF
    return
  fi

  cat <<'EOF'
Usage:
  ./miner-install.sh [--lang=zh|en] [--dry-run] [--yes]
  ./miner-install.sh <pool> [pool args...] [options]

Pools:
  qli       ./miner-install.sh qli <threads> <accessToken|qubicAddress> [alias]
  jetski    ./miner-install.sh jetski <wallet> [workername] [CPU threads] [--cpu] [--gpu] [--pplns|--solo]
  minerlab  ./miner-install.sh minerlab <username> [CPU threads] [alias]

Options:
  --lang=zh|en
  --change-lang
  --set-lang=zh|en
  --dry-run
  --yes
  --no-start
  --status
  --monitor
  --stop
  --stop-existing
  --force-download
  --ignore-threads N
  --use-avx2          Set CPU version=AVX2 for QLI/Minerlab
  --cpu | --no-cpu
  --gpu | --no-gpu
  --gpu-version CUDA|AMD
  --gpu-cards "-1,-1,0"
  --pps               QLI PPS mode
  --solo              QLI Solo mode; explicit JetSki SOLO mode
  --auto-update       Write autoUpdate=true for QLI
  --no-auto-update    Write autoUpdate=false for QLI
  --pplns             JetSki PPLNS mode (default)
EOF
}

is_zh() {
  [[ "$LANG_CHOICE" == "zh" ]]
}

msg() {
  local zh="$1"
  local en="$2"
  if is_zh; then
    printf '%s\n' "$zh"
  else
    printf '%s\n' "$en"
  fi
}

add_action() {
  ACTION_SUMMARY+=("$(msg "$1" "$2")")
}

add_risk() {
  RISK_SUMMARY+=("$(msg "$1" "$2")")
}

thread_mode_label() {
  case "$1" in
    auto) msg "自动" "auto" ;;
    fixed) msg "固定" "fixed" ;;
    ignore-n) msg "按保留线程计算" "computed from reserved threads" ;;
    disabled) msg "已关闭" "disabled" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

switch_label() {
  case "$1:$2" in
    1:zh) printf '开启' ;;
    0:zh) printf '关闭' ;;
    1:en) printf 'on' ;;
    0:en) printf 'off' ;;
  esac
}

info() {
  printf '%b%s%b\n' "$GREEN" "$*" "$NC"
}

warn() {
  printf '%b%s%b\n' "$YELLOW" "$*" "$NC"
}

err() {
  printf '%b%s%b\n' "$ERROR_COLOR" "$*" "$STDERR_NC" >&2
}

section() {
  printf '\n%b%s%b\n' "$HEADING" "$*" "$NC"
}

step() {
  printf '%b%s%b\n' "$BLUE" "$*" "$NC"
}

read_answer() {
  local answer_name="$1" question_text="$2"
  printf '%b%s%b' "$PROMPT_COLOR" "$question_text" "$STDERR_NC" >&2
  read -r "$answer_name"
}

record_option() {
  SEEN_OPTIONS+=("$1")
}

require_option_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    err "$(msg "选项 $option 缺少参数值。" "Option $option requires a value.")"
    exit 1
  fi
}

set_choice_flag() {
  local variable="$1"
  local value="$2"
  local label="$3"
  local current="${!variable}"
  if [[ -n "$current" && "$current" != "$value" ]]; then
    err "$(msg "选项 $label 存在互相冲突的设置。" "Conflicting values were provided for $label.")"
    exit 1
  fi
  printf -v "$variable" '%s' "$value"
}

set_action_mode() {
  local requested="$1"
  if [[ "$ACTION_MODE" != "install" && "$ACTION_MODE" != "$requested" ]]; then
    err "$(msg "不能同时指定 --$ACTION_MODE 和 --$requested。" "Cannot combine --$ACTION_MODE and --$requested.")"
    exit 1
  fi
  ACTION_MODE="$requested"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang=zh|--lang=cn)
        LANG_CHOICE="zh"
        ;;
      --lang=en)
        LANG_CHOICE="en"
        ;;
      --change-lang)
        CHANGE_LANG=1
        ;;
      --set-lang=zh|--set-lang=cn)
        SET_LANG_VALUE="zh"
        ;;
      --set-lang=en)
        SET_LANG_VALUE="en"
        ;;
      --set-lang)
        require_option_value "$1" "${2:-}"
        case "$2" in
          zh|cn) SET_LANG_VALUE="zh" ;;
          en) SET_LANG_VALUE="en" ;;
          *)
            err "$(msg '语言无效，请使用 zh 或 en。' 'Invalid language. Use zh or en.')"
            exit 1
            ;;
        esac
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      --yes|-y)
        AUTO_YES=1
        ;;
      --no-start)
        NO_START=1
        ;;
      --status)
        set_action_mode "status"
        ;;
      --monitor|--logs)
        set_action_mode "monitor"
        ;;
      --stop)
        set_action_mode "stop"
        ;;
      --stop-existing)
        STOP_EXISTING=1
        ;;
      --force-download)
        FORCE_DOWNLOAD=1
        ;;
      --ignore-threads)
        require_option_value "$1" "${2:-}"
        FLAG_IGNORE_THREADS="$2"
        record_option "ignore-threads"
        shift
        ;;
      --use-avx2|avx2)
        FLAG_USE_AVX2=1
        record_option "use-avx2"
        ;;
      --cpu)
        set_choice_flag FLAG_CPU 1 "CPU"
        record_option "cpu"
        ;;
      --no-cpu)
        set_choice_flag FLAG_CPU 0 "CPU"
        record_option "cpu"
        ;;
      --gpu)
        set_choice_flag FLAG_GPU 1 "GPU"
        record_option "gpu"
        ;;
      --no-gpu)
        set_choice_flag FLAG_GPU 0 "GPU"
        record_option "gpu"
        ;;
      --gpu-version)
        require_option_value "$1" "${2:-}"
        FLAG_GPU_VERSION="$2"
        record_option "gpu-version"
        shift
        ;;
      --gpu-cards)
        require_option_value "$1" "${2:-}"
        FLAG_GPU_CARDS="$2"
        record_option "gpu-cards"
        shift
        ;;
      --pps)
        set_choice_flag FLAG_PPS 1 "PPS/Solo"
        record_option "pps"
        ;;
      --solo)
        set_choice_flag FLAG_PPS 0 "PPS/Solo"
        record_option "solo"
        ;;
      --auto-update)
        set_choice_flag FLAG_AUTO_UPDATE 1 "autoUpdate"
        record_option "auto-update"
        ;;
      --no-auto-update)
        set_choice_flag FLAG_AUTO_UPDATE 0 "autoUpdate"
        record_option "auto-update"
        ;;
      --pplns)
        FLAG_PPLNS=1
        record_option "pplns"
        ;;
      --help|-h)
        HELP_REQUESTED=1
        ;;
      qli|jetski|minerlab)
        if [[ -z "$POOL" ]]; then
          POOL="$1"
          PARAM_MODE=1
        else
          err "$(msg "只能选择一个矿池，不能同时指定 $POOL 和 $1。" "Choose only one pool; $POOL and $1 cannot be used together.")"
          exit 1
        fi
        ;;
      --*)
        err "$(msg "未知选项: $1" "Unknown option: $1")"
        exit 1
        ;;
      *)
        POOL_ARGS+=("$1")
        ;;
    esac
    shift
  done

  if [[ "$HELP_REQUESTED" -eq 1 ]]; then
    if [[ -z "$LANG_CHOICE" ]]; then
      load_saved_language || set_language_from_env
    fi
    usage
    exit 0
  fi

  if [[ -z "$POOL" && -n "${MINER_POOL:-}" ]]; then
    POOL="${MINER_POOL,,}"
    PARAM_MODE=1
  fi

  if [[ "$ACTION_MODE" == "install" && -z "$POOL" && "${#POOL_ARGS[@]}" -gt 0 ]]; then
    err "$(msg "未知矿池: ${POOL_ARGS[0]}" "Unknown pool: ${POOL_ARGS[0]}")"
    exit 1
  fi
  case "$POOL" in
    ""|qli|jetski|minerlab) ;;
    *)
      err "$(msg "未知矿池: $POOL" "Unknown pool: $POOL")"
      exit 1
      ;;
  esac
}

validate_action_arguments() {
  [[ "$ACTION_MODE" == "install" ]] && return 0
  if [[ "${#POOL_ARGS[@]}" -gt 0 ]]; then
    err "$(msg "动作 --$ACTION_MODE 不接受额外位置参数。" "Action --$ACTION_MODE does not accept positional arguments.")"
    exit 1
  fi
  if [[ "${#SEEN_OPTIONS[@]}" -gt 0 || "$NO_START" -eq 1 \
    || "$STOP_EXISTING" -eq 1 || "$FORCE_DOWNLOAD" -eq 1 ]]; then
    err "$(msg "动作 --$ACTION_MODE 不能与安装选项组合。" "Action --$ACTION_MODE cannot be combined with install options.")"
    exit 1
  fi
}

option_allowed_for_pool() {
  local pool="$1"
  local option="$2"
  case "$pool:$option" in
    qli:ignore-threads|qli:use-avx2|qli:cpu|qli:gpu|qli:gpu-version|qli:gpu-cards|qli:pps|qli:solo|qli:auto-update)
      return 0
      ;;
    jetski:ignore-threads|jetski:cpu|jetski:gpu|jetski:gpu-version|jetski:gpu-cards|jetski:pplns|jetski:solo)
      return 0
      ;;
    minerlab:ignore-threads|minerlab:use-avx2|minerlab:cpu|minerlab:gpu|minerlab:gpu-version|minerlab:gpu-cards)
      return 0
      ;;
  esac
  return 1
}

validate_pool_options() {
  local option
  for option in "${SEEN_OPTIONS[@]}"; do
    if ! option_allowed_for_pool "$POOL" "$option"; then
      err "$(msg "选项 --$option 不适用于 $POOL。" "Option --$option is not valid for $POOL.")"
      exit 1
    fi
  done
}

validate_arg_count() {
  local max="$1"
  local usage_hint="$2"
  if [[ "${#POOL_ARGS[@]}" -gt "$max" ]]; then
    err "$(msg "位置参数过多。用法: $usage_hint" "Too many positional arguments. Usage: $usage_hint")"
    exit 1
  fi
}

set_language_from_env() {
  case "${LANG:-}" in
    zh*|cn*) LANG_CHOICE="zh" ;;
    *) LANG_CHOICE="en" ;;
  esac
}

valid_language() {
  [[ "$1" == "zh" || "$1" == "en" ]]
}

load_saved_language() {
  local saved=""
  [[ -f "$LANG_CONFIG_FILE" ]] || return 1
  saved="$(sed -n 's/^LANG_CHOICE=\(zh\|en\)$/\1/p' "$LANG_CONFIG_FILE" | head -n1)"
  if valid_language "$saved"; then
    LANG_CHOICE="$saved"
    return 0
  fi
  return 1
}

save_language_preference() {
  local lang="$1"
  local tmp

  if ! valid_language "$lang"; then
    err "$(msg '语言必须是 zh 或 en。' 'Language must be zh or en.')"
    exit 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  tmp="$LANG_CONFIG_FILE.tmp.$$"
  if ! printf 'LANG_CHOICE=%s\n' "$lang" > "$tmp" \
    || ! chmod 600 "$tmp" \
    || ! mv -f -- "$tmp" "$LANG_CONFIG_FILE"; then
    rm -f -- "$tmp"
    err "$(msg '保存语言偏好失败。' 'Failed to save language preference.')"
    exit 1
  fi
}

select_language_interactive() {
  local choice
  while true; do
    section "请选择语言 / Choose language"
    echo "1. 中文"
    echo "2. English"
    echo "0. 退出 / Exit"
    if ! read_answer choice "$(msg '选择 [0-2]: ' 'Select [0-2]: ')"; then
      echo
      err "输入已结束，安装已取消。 / Input closed; installation cancelled."
      exit 1
    fi
    case "$choice" in
      1|zh|ZH|cn|CN)
        LANG_CHOICE="zh"
        return 0
        ;;
      2|en|EN)
        LANG_CHOICE="en"
        return 0
        ;;
      0) exit 0 ;;
      *)
        err "请输入 0-2。 / Please enter 0-2."
        ;;
    esac
  done
}

ensure_language() {
  [[ -n "$LANG_CHOICE" ]] && return 0

  if load_saved_language; then
    return 0
  fi

  if [[ "$AUTO_YES" -eq 0 && "$ACTION_MODE" == "install" ]]; then
    select_language_interactive
    save_language_preference "$LANG_CHOICE"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      warn "$(msg '预演模式：语言只用于本次运行，不会保存偏好。' 'Dry-run: the language applies to this run only and was not saved.')"
    fi
  else
    set_language_from_env
  fi
}

handle_language_change() {
  if [[ -n "$SET_LANG_VALUE" ]]; then
    LANG_CHOICE="$SET_LANG_VALUE"
    save_language_preference "$LANG_CHOICE"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      msg '预演模式：语言偏好未保存。' 'Dry-run: language preference was not saved.'
    else
      msg '语言偏好已保存。' 'Language preference saved.'
    fi
    exit 0
  fi

  if [[ "$CHANGE_LANG" -eq 1 ]]; then
    if [[ -z "$LANG_CHOICE" ]]; then
      load_saved_language || set_language_from_env
    fi
    select_language_interactive
    save_language_preference "$LANG_CHOICE"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      msg '预演模式：语言偏好未保存。' 'Dry-run: language preference was not saved.'
    else
      msg '语言偏好已保存。' 'Language preference saved.'
    fi
    exit 0
  fi
}

ask() {
  local prompt="$1"
  local var_name="$2"
  local default="${3:-}"
  local required="${4:-0}"
  local value=""

  while true; do
    if [[ -n "$default" ]]; then
      if ! read_answer value "$prompt [$default]: "; then
        echo
        err "$(msg '输入已结束，安装已取消。' 'Input closed; installation cancelled.')"
        exit 1
      fi
      value="${value:-$default}"
    else
      if ! read_answer value "$prompt: "; then
        echo
        err "$(msg '输入已结束，安装已取消。' 'Input closed; installation cancelled.')"
        exit 1
      fi
    fi
    if [[ "$required" -eq 0 || -n "$(trim "$value")" ]]; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi
    err "$(msg '该字段不能为空。' 'This value is required.')"
  done
}

ask_yes_no() {
  local prompt="$1"
  local default_yes="${2:-0}"
  local value=""
  local choices

  if [[ "$AUTO_YES" -eq 1 ]]; then
    return 0
  fi

  if [[ "$default_yes" -eq 1 ]]; then
    choices='[Y/n]'
  else
    choices='[y/N]'
  fi

  while true; do
    if ! read_answer value "$prompt $choices: "; then
      echo
      err "$(msg '输入已结束，操作已取消。' 'Input closed; action cancelled.')"
      exit 1
    fi
    value="$(trim "$value")"
    value="${value,,}"
    case "$value" in
      y|yes|是) return 0 ;;
      n|no|否) return 1 ;;
      '')
        if [[ "$default_yes" -eq 1 ]]; then
          return 0
        fi
        return 1
        ;;
      *) err "$(msg '请输入 y 或 n。' 'Please enter y or n.')" ;;
    esac
  done
}

ensure_dir() {
  local dir="$1"
  step "mkdir -p $(printf '%q' "$dir")"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! mkdir -p -- "$dir"; then
      err "$(msg '无法创建目录:' 'Could not create directory:') $dir"
      exit 1
    fi
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  local dir tmp backup
  step "$(msg '写入文件' 'Write file'): $path"
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  if [[ -L "$path" ]]; then
    err "$(msg '拒绝覆盖符号链接:' 'Refusing to overwrite symlink:') $path"
    exit 1
  fi
  dir="$(dirname "$path")"
  if ! mkdir -p -- "$dir"; then
    err "$(msg '无法创建配置目录:' 'Could not create config directory:') $dir"
    exit 1
  fi
  if ! tmp="$(mktemp "$dir/.miner-install.tmp.XXXXXX")"; then
    err "$(msg '无法创建临时配置文件。' 'Could not create temporary config file.')"
    exit 1
  fi
  backup="$path.previous"
  if [[ -L "$backup" ]]; then
    rm -f -- "$tmp"
    err "$(msg '拒绝覆盖备份符号链接:' 'Refusing to overwrite backup symlink:') $backup"
    exit 1
  fi
  if [[ -f "$path" ]]; then
    if ! cp -- "$path" "$backup" || ! chmod 600 "$backup"; then
      rm -f -- "$tmp"
      err "$(msg '备份原配置失败:' 'Failed to back up existing config:') $path"
      exit 1
    fi
  fi
  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f -- "$tmp"
    err "$(msg '写入临时配置失败:' 'Failed to write temporary config:') $tmp"
    exit 1
  fi
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    err "$(msg '原子替换配置失败:' 'Atomic config replacement failed:') $path"
    exit 1
  fi
}

argv_string() {
  local result="" quoted arg
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    result+="${result:+ }$quoted"
  done
  printf '%s' "$result"
}

set_command_displays() {
  START_CMD="cd $(printf '%q' "$INSTALL_DIR") && setsid $(argv_string "${START_ARGS[@]}") >> $(printf '%q' "$LOG_PATH") 2>&1"
  if [[ "${#SETUP_ARGS[@]}" -gt 0 ]]; then
    SETUP_CMD="cd $(printf '%q' "$INSTALL_DIR") && $(argv_string "${SETUP_ARGS[@]}")"
  else
    SETUP_CMD=""
  fi
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

is_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

require_int() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then
    err "$name $(msg '必须是大于等于 0 的整数，且不能包含前导零。' 'must be an integer >= 0 without leading zeros.')"
    exit 1
  fi
}

validate_jwt() {
  local token="$1"
  local payload exp
  [[ "${#token}" -ge 100 ]] || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || return 1
  payload="$(jwt_payload "$token")" || return 1
  [[ "$payload" == \{*\} && ! "$payload" =~ [[:cntrl:]] ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  else
    # Signed QLI tokens contain these claims; requiring them also rejects
    # merely brace-wrapped text when a JSON parser is unavailable.
    [[ "$payload" =~ \"iss\"[[:space:]]*:[[:space:]]*\"[^\"]+\" ]] || return 1
    [[ "$payload" =~ \"aud\"[[:space:]]*:[[:space:]]*\"[^\"]+\" ]] || return 1
  fi
  exp="$(jwt_numeric_claim "$token" exp || true)"
  [[ "$exp" =~ ^[0-9]+$ ]]
}

validate_qli_payout_id() {
  [[ "$1" =~ ^[A-Z]{60}$ ]]
}

validate_gpu_cards() {
  [[ "$1" =~ ^(-1|[0-9]+)(,(-1|[0-9]+))*$ ]]
}

jwt_payload() {
  local token="$1"
  local payload="${token#*.}"
  payload="${payload%%.*}"
  payload="${payload//-/+}"
  payload="${payload//_/\/}"
  case $((${#payload} % 4)) in
    0) ;;
    2) payload="${payload}==" ;;
    3) payload="${payload}=" ;;
    *) return 1 ;;
  esac
  printf '%s' "$payload" | base64 -d 2>/dev/null
}

jwt_numeric_claim() {
  local token="$1"
  local claim="$2"
  local payload
  payload="$(jwt_payload "$token")" || return 1
  printf '%s' "$payload" \
    | sed -n "s/.*\"$claim\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" \
    | head -n1
}

validate_jwt_time() {
  local token="$1"
  local label="$2"
  local now exp nbf
  now="$(date +%s)"
  exp="$(jwt_numeric_claim "$token" exp || true)"
  nbf="$(jwt_numeric_claim "$token" nbf || true)"

  if [[ -n "$exp" ]] && (( 10#$exp <= now )); then
    err "$(msg "$label 已过期。" "$label has expired.")"
    return 1
  fi
  if [[ -n "$nbf" ]] && (( 10#$nbf > now + 300 )); then
    err "$(msg "$label 尚未生效。" "$label is not valid yet.")"
    return 1
  fi
}

reject_control_chars() {
  local label="$1"
  local value="$2"
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    err "$(msg "$label 不能包含控制字符或换行。" "$label cannot contain control characters or newlines.")"
    exit 1
  fi
}

assign_bool() {
  local target="$1"
  local name="$2"
  local value="$3"
  local parsed
  if ! parsed="$(bool_value "$value")"; then
    err "$(msg "$name 必须是 true/false 或 1/0。" "$name must be true/false or 1/0.")"
    exit 1
  fi
  printf -v "$target" '%s' "$parsed"
}

bool_value() {
  case "${1,,}" in
    1|true|yes|y|on) echo "1" ;;
    0|false|no|n|off) echo "0" ;;
    *) return 1 ;;
  esac
}

cpu_count() {
  nproc 2>/dev/null || echo 1
}

default_worker() {
  hostname 2>/dev/null || echo "miner"
}

set_threads() {
  local fixed="$1"
  local ignore="$2"
  local total
  total="$(cpu_count)"

  if [[ -n "$ignore" ]]; then
    require_int "ignoreThreads" "$ignore"
    if [[ "$ignore" -ge "$total" ]]; then
      err "$(msg '保留线程数不能大于等于 CPU 总线程数。' 'ignoreThreads must be less than total CPU threads.')"
      exit 1
    fi
    THREAD_MODE="ignore-n"
    THREADS=$((total - ignore))
    return
  fi

  if [[ -n "$fixed" ]]; then
    require_int "threads" "$fixed"
    THREADS="$fixed"
    if [[ "$THREADS" == "0" ]]; then
      THREAD_MODE="auto"
    else
      THREAD_MODE="fixed"
    fi
    return
  fi

  THREAD_MODE="auto"
  THREADS="0"
}

github_latest_asset_url() {
  local repo="$1"
  local pattern="$2"
  curl -fsSL --connect-timeout 8 --max-time 15 \
    "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
    | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | grep -Ei "$pattern" \
    | head -n1
}

qli_latest_url() {
  local script package
  script="$(curl -fsSL --connect-timeout 8 --max-time 20 --max-filesize 1048576 \
    https://dl.qubic.li/cloud-init/qli-Service-install-auto.sh 2>/dev/null || true)"
  package="$(printf '%s\n' "$script" | sed -n 's/^package=\(qli-Client-[^[:space:]]*Linux-x64\.tar\.gz\)$/\1/p' | head -n1)"
  if [[ -n "$package" ]]; then
    printf 'https://dl.qubic.li/downloads/%s\n' "$package"
    return 0
  fi
  printf 'https://dl.qubic.li/downloads/qli-Client-3.8.10-Linux-x64.tar.gz\n'
  return 1
}

jetski_latest_url() {
  local mode="$1"
  local pattern fallback url
  if [[ "$mode" == "solo" ]]; then
    pattern='qubjetski-latest\.tar\.gz$'
    fallback='https://github.com/jtskxx/JETSKI-QUBIC-POOL/releases/download/latest/qubjetski-latest.tar.gz'
  else
    pattern='qubjetski\.PPLNS-latest\.tar\.gz$'
    fallback='https://github.com/jtskxx/JETSKI-QUBIC-POOL/releases/download/latest/qubjetski.PPLNS-latest.tar.gz'
  fi

  url="$(github_latest_asset_url "jtskxx/JETSKI-QUBIC-POOL" "$pattern" || true)"
  printf '%s\n' "${url:-$fallback}"
}

set_download_trust() {
  local url="$1"
  local digest="${2,,}"
  local source="$3"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  DOWNLOAD_TRUST_URL="$url"
  DOWNLOAD_TRUST_SHA256="$digest"
  DOWNLOAD_TRUST_SOURCE="$source"
}

github_release_api_asset_sha256() {
  local url="$1"
  local repo tag api payload digest
  if [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/?]+)$ ]]; then
    repo="${BASH_REMATCH[1]}"
    tag="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
    && "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  if [[ "$tag" == "latest" ]]; then
    api="https://api.github.com/repos/$repo/releases/latest"
  else
    api="https://api.github.com/repos/$repo/releases/tags/$tag"
  fi
  payload="$(curl -fsSL --connect-timeout 8 --max-time 20 --max-filesize 4194304 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api" 2>/dev/null || true)"
  [[ -n "$payload" ]] || return 1

  # GitHub returns digest before browser_download_url for each release asset.
  # Match the exact URL so a checksum from a neighboring asset cannot be reused.
  digest="$(printf '%s\n' "$payload" | awk -v wanted="$url" '
    match($0, /"digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-fA-F]+"/) {
      current = substr($0, RSTART, RLENGTH)
      sub(/^.*sha256:/, "", current)
      sub(/".*$/, "", current)
      current = tolower(current)
    }
    match($0, /"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"/) {
      asset_url = substr($0, RSTART, RLENGTH)
      sub(/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", asset_url)
      sub(/"$/, "", asset_url)
      if (asset_url == wanted && current != "") {
        print current
        exit
      }
      current = ""
    }
  ')"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

github_release_asset_sha256() {
  local url="$1"
  local repo tag asset page wanted digest
  if [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/?]+)$ ]]; then
    repo="${BASH_REMATCH[1]}"
    tag="${BASH_REMATCH[2]}"
    asset="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
    && "$tag" =~ ^[A-Za-z0-9._-]+$ \
    && "$asset" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  digest="$(github_release_api_asset_sha256 "$url" || true)"
  if [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' "$digest"
    return 0
  fi

  page="$(curl -fsSL --connect-timeout 8 --max-time 20 --max-filesize 2097152 \
    "https://github.com/$repo/releases/expanded_assets/$tag" 2>/dev/null || true)"
  [[ -n "$page" ]] || return 1
  wanted="href=\"/$repo/releases/download/$tag/$asset\""
  digest="$(printf '%s\n' "$page" | awk -v wanted="$wanted" '
    index($0, wanted) { found = 1; next }
    found && match($0, /sha256:[0-9a-fA-F]+/) {
      value = substr($0, RSTART + 7, 64)
      print tolower(value)
      exit
    }
    found && /<\/li>/ { exit }
  ')"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

jetski_release_sha256() {
  local mode="$1"
  local hash_name raw digest
  if [[ "$mode" == "solo" ]]; then
    hash_name="qubjetski-latest.hash"
  else
    hash_name="qubjetski.PPLNS-latest.hash"
  fi
  raw="$(curl -fsSL --connect-timeout 8 --max-time 20 --max-filesize 1024 \
    "https://github.com/jtskxx/JETSKI-QUBIC-POOL/releases/download/latest/$hash_name" \
    2>/dev/null)" || return 1
  digest="$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

pool_label() {
  case "$1" in
    qli) echo "QLI" ;;
    jetski) echo "JetSki" ;;
    minerlab) echo "Minerlab" ;;
    *) msg '未知' 'Unknown' ;;
  esac
}

binary_path_for_pool() {
  case "$1" in
    qli) printf '%s\n' "$MINERS_DIR/qli/qli-Client" ;;
    jetski) printf '%s\n' "$MINERS_DIR/jetski/qubjetski-Client" ;;
    minerlab) printf '%s\n' "$MINERS_DIR/minerlab/qlab-miner" ;;
    *) return 1 ;;
  esac
}

legacy_minerlab_binary_path() {
  printf '%s\n' "$MINERS_DIR/minerlab/qli-Client"
}

state_path_for_pool() {
  case "$1" in
    qli|jetski|minerlab)
      printf '%s\n' "$MINERS_DIR/$1/.miner-install.state"
      ;;
    *) return 1 ;;
  esac
}

canonical_path() {
  readlink -m -- "$1" 2>/dev/null || printf '%s\n' "$1"
}

proc_exe_path() {
  local value
  value="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
  value="${value% (deleted)}"
  canonical_path "$value"
}

process_start_ticks() {
  local stat
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  stat="${stat##*) }"
  awk '{print $20}' <<< "$stat"
}

process_group_session() {
  local stat
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  stat="${stat##*) }"
  # After removing pid/comm, fields 3 and 4 are pgrp and session.
  awk '{print $3, $4}' <<< "$stat"
}

pid_matches_pool() {
  local pid="$1"
  local pool="$2"
  local actual expected
  [[ "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]] || return 1
  actual="$(proc_exe_path "$pid")" || return 1
  expected="$(canonical_path "$(binary_path_for_pool "$pool")")"
  if [[ "$actual" == "$expected" ]]; then
    return 0
  fi
  if [[ "$pool" == "minerlab" ]]; then
    expected="$(canonical_path "$(legacy_minerlab_binary_path)")"
    [[ "$actual" == "$expected" ]] && return 0
  fi
  return 1
}

state_value() {
  local path="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$path" 2>/dev/null | head -n1
}

state_pid_for_pool() {
  local pool="$1"
  local state pid saved_ticks current_ticks
  state="$(state_path_for_pool "$pool")"
  [[ -f "$state" ]] || return 1
  pid="$(state_value "$state" pid)"
  saved_ticks="$(state_value "$state" start_ticks)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  pid_matches_pool "$pid" "$pool" || return 1
  if [[ -n "$saved_ticks" ]]; then
    current_ticks="$(process_start_ticks "$pid" || true)"
    [[ "$current_ticks" == "$saved_ticks" ]] || return 1
  fi
  printf '%s\n' "$pid"
}

pool_pids() {
  local pool="$1"
  local expected binary_name state_pid pid actual
  local -a expected_paths=()
  local -A seen=()

  state_pid="$(state_pid_for_pool "$pool" || true)"
  if [[ -n "$state_pid" ]]; then
    seen["$state_pid"]=1
    printf '%s\n' "$state_pid"
  fi

  expected_paths+=("$(canonical_path "$(binary_path_for_pool "$pool")")")
  if [[ "$pool" == "minerlab" ]]; then
    expected_paths+=("$(canonical_path "$(legacy_minerlab_binary_path)")")
  fi
  for expected in "${expected_paths[@]}"; do
    binary_name="$(basename "$expected")"
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      [[ -n "${seen[$pid]:-}" ]] && continue
      actual="$(proc_exe_path "$pid" || true)"
      if [[ -n "$actual" && "$actual" == "$expected" ]]; then
        seen["$pid"]=1
        printf '%s\n' "$pid"
      fi
    done < <(pgrep -f -- "$binary_name" 2>/dev/null || true)
  done
}

legacy_qlab_active() {
  command -v systemctl >/dev/null 2>&1 \
    && systemctl is-active --quiet qlab >/dev/null 2>&1
}

pool_process_lines() {
  local pool="$1"
  local pid cmd
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    printf '%s [%s] %s\n' "$pid" "$(pool_label "$pool")" "${cmd:-$(binary_path_for_pool "$pool")}"
  done < <(pool_pids "$pool")
}

known_miners_running() {
  local pool lines
  for pool in qli jetski minerlab; do
    lines="$(pool_process_lines "$pool")"
    [[ -n "$lines" ]] && printf '%s\n' "$lines"
  done
  if legacy_qlab_active; then
    printf '%s\n' "systemd [Minerlab legacy] qlab.service"
  fi
}

detect_running_pool() {
  local pool
  if legacy_qlab_active; then
    echo "minerlab"
    return 0
  fi
  for pool in minerlab jetski qli; do
    if [[ -n "$(pool_pids "$pool")" ]]; then
      echo "$pool"
      return 0
    fi
  done
  return 1
}

validated_state_log_for_pool() {
  local pool="$1"
  local state base candidate saved_log
  state="$(state_path_for_pool "$pool")" || return 1
  state_pid_for_pool "$pool" >/dev/null || return 1
  saved_log="$(state_value "$state" log)"
  [[ -n "$saved_log" && "$saved_log" = /* && ! "$saved_log" =~ [[:cntrl:]] ]] || return 1
  base="$(canonical_path "$MINERS_DIR/$pool")"
  candidate="$(canonical_path "$saved_log")"
  [[ "$candidate" == "$base/"* ]] || return 1
  printf '%s\n' "$candidate"
}

log_path_for_pool() {
  local saved_log
  saved_log="$(validated_state_log_for_pool "$1" || true)"
  if [[ -n "$saved_log" ]]; then
    printf '%s\n' "$saved_log"
    return 0
  fi
  case "$1" in
    qli) echo "$MINERS_DIR/qli/qli.log" ;;
    jetski) echo "$MINERS_DIR/jetski/jetski.log" ;;
    minerlab) echo "$MINERS_DIR/minerlab/minerlab.log" ;;
    *)
      echo "$MINERS_DIR/qli/qli.log"
      ;;
  esac
}

script_entry_hint() {
  if [[ "$STREAMED_ENTRYPOINT" -eq 1 ]]; then
    printf "curl -fsSL --proto '=https' %s | bash -s --" "$REMOTE_SCRIPT_URL"
  else
    printf '%s/miner-install.sh' "$BASE_DIR"
  fi
}

script_stop_hint() {
  local pool="$1"
  local lang_opt="--lang=${LANG_CHOICE:-en}"
  if [[ -n "$pool" && "$pool" != "unknown" ]]; then
    echo "$(script_entry_hint) $pool --stop $lang_opt"
  else
    echo "$(script_entry_hint) --stop $lang_opt"
  fi
}

show_status() {
  local running detected log_path
  running="$(known_miners_running)"
  detected="$(detect_running_pool || true)"

  info "$(msg '运行状态' 'Runtime status')"
  if [[ -z "$running" ]]; then
    msg '未检测到正在运行的已知 miner。' 'No known running miner detected.'
    return 0
  fi

  printf '%s\n' "$running"
  if [[ -n "$detected" ]]; then
    log_path="$(log_path_for_pool "$detected")"
    echo "$(msg '识别矿池' 'Detected pool'): $(pool_label "$detected")"
    if [[ "$detected" == "minerlab" ]] && legacy_qlab_active \
      && [[ -z "$(pool_pids minerlab)" ]]; then
      echo "$(msg '旧服务日志' 'Legacy service log'): tail -f '/var/log/qlab.log'"
      echo "$(msg '旧服务停止' 'Stop legacy service'): sudo systemctl stop qlab"
    else
      echo "$(msg '日志' 'Log'): tail -f '$log_path'"
      echo "$(msg '停止' 'Stop'): $(script_stop_hint "$detected")"
    fi
  else
    echo "$(msg '停止' 'Stop'): $(script_stop_hint unknown)"
  fi
}

tail_log() {
  local path="$1"
  step "tail -f $(printf '%q' "$path")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    warn "$(msg '日志文件还不存在:' 'Log file does not exist yet:') $path"
    return 1
  fi
  tail -f "$path"
}

monitor_pool() {
  local pool="$1"
  local log_path
  if [[ -z "$pool" ]]; then
    pool="$(detect_running_pool || true)"
  fi
  if [[ -z "$pool" && -n "$POOL" ]]; then
    pool="$POOL"
  fi
  if [[ -z "$pool" ]]; then
    warn "$(msg '未检测到正在运行的 miner，无法自动选择日志。' 'No running miner detected; cannot select log automatically.')"
    return 1
  fi
  if [[ "$pool" == "minerlab" ]] && legacy_qlab_active \
    && [[ -z "$(pool_pids minerlab)" ]]; then
    log_path="/var/log/qlab.log"
  else
    log_path="$(log_path_for_pool "$pool")"
  fi
  tail_log "$log_path"
}

clear_pool_state() {
  local pool="$1"
  local state
  state="$(state_path_for_pool "$pool")"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  rm -f -- "$state"
}

stop_target_alive() {
  local pid="$1"
  local pool="$2"
  local scope="$3"
  local target="$4"
  local group_id member_pid stat state pgid sid

  if [[ "$scope" == "group" ]]; then
    group_id="${target#-}"
    while IFS= read -r member_pid; do
      [[ "$member_pid" =~ ^[0-9]+$ ]] || continue
      IFS= read -r stat < "/proc/$member_pid/stat" 2>/dev/null || continue
      stat="${stat##*) }"
      state=""
      pgid=""
      sid=""
      read -r state _ pgid sid _ <<< "$stat"
      if [[ "$pgid" == "$group_id" && "$sid" == "$group_id" \
        && "$state" != "Z" && "$state" != "X" && "$state" != "x" ]]; then
        return 0
      fi
    done < <(pgrep -g "$group_id" 2>/dev/null || true)
    return 1
  fi

  pid_matches_pool "$pid" "$pool"
}

wait_for_stop_target() {
  local pid="$1"
  local pool="$2"
  local scope="$3"
  local target="$4"
  local attempts="$5"
  local attempt

  for ((attempt = 0; attempt < attempts; attempt++)); do
    stop_target_alive "$pid" "$pool" "$scope" "$target" || return 0
    sleep 0.1
  done
  ! stop_target_alive "$pid" "$pool" "$scope" "$target"
}

signal_stop_target() {
  local pid="$1"
  local pool="$2"
  local scope="$3"
  local target="$4"
  local signal="$5"

  if [[ "$scope" == "group" ]]; then
    kill -s "$signal" -- "$target" 2>/dev/null
    return
  fi

  # Recheck the executable before every direct-PID signal to prevent PID reuse.
  pid_matches_pool "$pid" "$pool" || return 1
  kill -s "$signal" -- "$target" 2>/dev/null
}

stop_pool_processes() {
  local pool="$1"
  local found=0 failed=0 stopped
  local pid group_session pgid sid scope target target_zh target_en

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    pid_matches_pool "$pid" "$pool" || continue
    found=1

    scope="pid"
    target="$pid"
    target_zh="已验证的 miner PID"
    target_en="verified miner PID"
    group_session="$(process_group_session "$pid" || true)"
    pgid=""
    sid=""
    read -r pgid sid <<< "$group_session"
    if [[ "$pgid" == "$pid" && "$sid" == "$pid" ]]; then
      # setsid gives script-started miners an isolated group, so their children
      # can receive the same shutdown signal without touching the user's shell.
      scope="group"
      target="-$pid"
      target_zh="已验证的独立 miner 进程组"
      target_en="verified isolated miner process group"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      if [[ "$pool" == "qli" || "$pool" == "minerlab" ]]; then
        step "kill -s INT -- $target # $(pool_label "$pool"): $target_en"
        step "kill -s TERM -- $target # $(msg '仅在 INT 超时后' 'only if INT times out')"
      else
        step "kill -s TERM -- $target # $(pool_label "$pool"): $target_en"
      fi
      step "kill -s KILL -- $target # $(msg '仅在正常停止超时后' 'only if graceful stop times out')"
      continue
    fi

    stopped=0
    if [[ "$pool" == "qli" || "$pool" == "minerlab" ]]; then
      signal_stop_target "$pid" "$pool" "$scope" "$target" INT || true
      if wait_for_stop_target "$pid" "$pool" "$scope" "$target" 10; then
        stopped=1
      else
        warn "$(pool_label "$pool") $(msg '未在 1 秒内响应 Ctrl+C 信号，改用 TERM。' 'did not respond to the Ctrl+C signal within 1 second; trying TERM.')"
        signal_stop_target "$pid" "$pool" "$scope" "$target" TERM || true
        if wait_for_stop_target "$pid" "$pool" "$scope" "$target" 20; then
          stopped=1
        fi
      fi
    else
      signal_stop_target "$pid" "$pool" "$scope" "$target" TERM || true
      if wait_for_stop_target "$pid" "$pool" "$scope" "$target" 50; then
        stopped=1
      fi
    fi

    if [[ "$stopped" -eq 0 ]] && stop_target_alive "$pid" "$pool" "$scope" "$target"; then
      warn "$(msg "进程仍未正常退出，将强制停止这个${target_zh}:" "Process is still running; force-stopping this ${target_en}:") $pid"
      signal_stop_target "$pid" "$pool" "$scope" "$target" KILL || true
      if wait_for_stop_target "$pid" "$pool" "$scope" "$target" 10; then
        stopped=1
      fi
    fi
    if [[ "$stopped" -eq 0 ]] && stop_target_alive "$pid" "$pool" "$scope" "$target"; then
      err "$(msg '无法停止经过验证的 miner 目标:' 'Failed to stop the verified miner target:') $pid"
      failed=1
    fi
  done < <(pool_pids "$pool")

  if [[ "$found" -eq 1 && "$failed" -eq 0 ]]; then
    clear_pool_state "$pool"
  fi
  [[ "$failed" -eq 0 ]]
}

stop_pool() {
  local pool="$1"
  local running=""
  local target failed=0
  local -a targets=()

  if [[ -n "$pool" ]]; then
    targets=("$pool")
    running="$(pool_process_lines "$pool")"
    if [[ "$pool" == "minerlab" ]] && legacy_qlab_active; then
      running+="${running:+$'\n'}systemd [Minerlab legacy] qlab.service"
    fi
  else
    targets=(qli jetski minerlab)
    running="$(known_miners_running)"
  fi

  if [[ -z "$running" ]]; then
    msg '未检测到正在运行的已知 miner。' 'No known running miner detected.'
    return 0
  fi

  warn "$(msg '将停止以下已知 miner 进程:' 'Will stop these known miner processes:')"
  printf '%s\n' "$running"

  if [[ "$AUTO_YES" -eq 0 ]]; then
    if ! ask_yes_no "$(msg '确认停止?' 'Confirm stop?')" 0; then
      warn "$(msg '已取消停止。' 'Stop cancelled.')"
      return 0
    fi
  fi

  for target in "${targets[@]}"; do
    stop_pool_processes "$target" || failed=1
  done
  if legacy_qlab_active && { [[ -z "$pool" ]] || [[ "$pool" == "minerlab" ]]; }; then
    warn "$(msg '检测到旧 qlab.service 正在运行；轻量脚本不会请求管理员权限。需要时请手动执行: sudo systemctl stop qlab' 'Legacy qlab.service is running; this lightweight script will not request administrator privileges. If needed, run: sudo systemctl stop qlab')"
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    err "$(msg '至少一个 miner 未能确认停止。' 'At least one miner could not be confirmed stopped.')"
    return 1
  fi
  info "$(msg '已确认目标 miner 停止。' 'Confirmed that the target miner stopped.')"
}

handle_action_mode() {
  local target_pool="$POOL"
  case "$ACTION_MODE" in
    status)
      show_status
      exit 0
      ;;
    monitor)
      monitor_pool "$target_pool"
      exit $?
      ;;
    stop)
      stop_pool "$target_pool"
      exit $?
      ;;
  esac
}

manage_existing_miners() {
  local running choice detected
  running="$(known_miners_running)"
  [[ -z "$running" ]] && return 0

  detected="$(detect_running_pool || true)"
  while true; do
    section "$(msg '检测到已有 miner 正在运行' 'Existing miner is running')"
    [[ -n "$detected" ]] && echo "$(msg '识别矿池' 'Detected pool'): $(pool_label "$detected")"
    msg '请选择操作：' 'Choose an action:'
    echo "1. $(msg '查看状态' 'Show status')"
    echo "2. $(msg '查看日志' 'Monitor log')"
    echo "3. $(msg '停止运行中的 miner' 'Stop running miner')"
    echo "4. $(msg '继续安装/切换矿池' 'Continue install/switch pool')"
    echo "5. $(msg '退出' 'Exit')"
    if ! read_answer choice "$(msg '选择 [1-5]: ' 'Select [1-5]: ')"; then
      echo
      err "$(msg '输入已结束，操作已取消。' 'Input closed; action cancelled.')"
      exit 1
    fi
    case "$choice" in
      1)
        show_status
        ;;
      2)
        monitor_pool "$detected"
        exit $?
        ;;
      3)
        stop_pool "$detected"
        exit $?
        ;;
      4)
        return 0
        ;;
      5)
        exit 0
        ;;
      *)
        err "$(msg '请输入 1-5。' 'Please enter 1-5.')"
        ;;
    esac
  done
}

handle_interrupt() {
  echo
  local detected log_path
  detected="$(detect_running_pool || true)"

  if [[ "$START_ATTEMPTED" -eq 1 || -n "$detected" ]]; then
    warn "$(msg '已退出脚本/日志查看；如果 miner 已经启动，它会继续在后台运行。' 'Exited the script/log viewer; if the miner was started, it continues running in the background.')"
    if [[ -n "$detected" ]]; then
      log_path="$(log_path_for_pool "$detected")"
      echo "$(msg '日志' 'Log'): tail -f '$log_path'"
      echo "$(msg '停止' 'Stop'): $(script_stop_hint "$detected")"
    else
      echo "$(msg '查看状态' 'Status'): $(script_entry_hint) --status --lang=${LANG_CHOICE:-en}"
      echo "$(msg '停止' 'Stop'): $(script_entry_hint) --stop --lang=${LANG_CHOICE:-en}"
    fi
  else
    warn "$(msg '已取消，miner 尚未启动。' 'Cancelled; miner was not started yet.')"
  fi
  exit 130
}

running_as_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

environment_check() {
  section "$(msg '环境检查' 'Environment check')"
  local os arch missing=()
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  echo "OS: $os"
  echo "ARCH: $arch"

  if [[ "$ACTION_MODE" == "install" ]]; then
    if [[ "$DRY_RUN" -eq 0 ]] && running_as_root; then
      err "$(msg '拒绝以 root 运行安装流程。QLI/JetSki 会继续下载并执行 worker，请使用普通用户。' 'Refusing to install as root. QLI/JetSki download and execute workers at runtime; use an unprivileged user.')"
      exit 1
    fi
    if [[ "$os" != "Linux" ]]; then
      err "$(msg '当前安装包只支持 Linux。' 'Current miner packages support Linux only.')"
      exit 1
    fi
    case "$arch" in
      x86_64|amd64) ;;
      *)
        err "$(msg '当前安装包只支持 x86_64/amd64。' 'Current miner packages support x86_64/amd64 only.')"
        exit 1
        ;;
    esac

    for cmd in bash curl tar setsid flock pgrep readlink base64 sha256sum awk sed grep find mktemp sort stat tail; do
      command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
      missing+=("wget/curl")
    fi
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    err "$(msg '缺少必需依赖:' 'Missing required dependencies:') ${missing[*]}"
    exit 1
  fi

  local running
  running="$(known_miners_running)"
  if [[ -n "$running" ]]; then
    warn "$(msg '检测到可能正在运行的 miner:' 'Possible running miners detected:')"
    printf '%s\n' "$running"
  fi
}

version_at_least() {
  local actual="$1"
  local minimum="$2"
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n1)" == "$minimum" ]]
}

validate_pool_platform() {
  local glibc_version
  case "$POOL" in
    qli|minerlab)
      glibc_version="$(ldd --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+' | tail -n1)"
      if [[ -z "$glibc_version" ]] || ! version_at_least "$glibc_version" "2.31"; then
        err "$(msg 'QLI 系客户端需要 glibc 2.31 或更高版本。' 'QLI-family clients require glibc 2.31 or newer.')"
        exit 1
      fi
      ;;
  esac
}

acquire_install_lock() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if ! command -v flock >/dev/null 2>&1; then
    err "$(msg '缺少 flock，无法安全防止两个安装流程同时改写文件。' 'flock is required to prevent concurrent installers from modifying files.')"
    exit 1
  fi
  if [[ -L "$LOCK_PATH" || ( -e "$LOCK_PATH" && ! -f "$LOCK_PATH" ) ]]; then
    err "$(msg '拒绝使用符号链接或非普通文件形式的安装锁。' 'Refusing a symlinked or non-regular install lock.')"
    exit 1
  fi
  if ! exec 9>"$LOCK_PATH"; then
    err "$(msg '无法创建安装锁。' 'Could not create the installer lock.')"
    exit 1
  fi
  if ! chmod 600 "$LOCK_PATH"; then
    err "$(msg '无法保护安装锁权限。' 'Could not secure the install lock permissions.')"
    exit 1
  fi
  if ! flock -n 9; then
    err "$(msg '另一个安装流程正在运行，请等待它结束。' 'Another installer is running; wait for it to finish.')"
    exit 1
  fi
}

validate_mutation_paths() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  local path
  for path in "$MINERS_DIR" "$DOWNLOADS_DIR" "$INSTALL_DIR"; do
    if [[ -L "$path" ]]; then
      err "$(msg '拒绝通过符号链接形式的运行目录写入:' 'Refusing to write through a symlinked runtime directory:') $path"
      return 1
    fi
    if [[ -e "$path" && ! -d "$path" ]]; then
      err "$(msg '运行目录路径已存在但不是目录:' 'Runtime directory path exists but is not a directory:') $path"
      return 1
    fi
  done
}

select_pool_interactive() {
  local choice
  while true; do
    section "$(msg '请选择要安装的矿池' 'Choose pool to install')"
    echo "1. QLI"
    echo "2. JetSki"
    echo "3. Minerlab"
    echo "0. $(msg '退出' 'Exit')"
    if ! read_answer choice "$(msg '选择 [0-3]: ' 'Select [0-3]: ')"; then
      echo
      err "$(msg '输入已结束，安装已取消。' 'Input closed; installation cancelled.')"
      exit 1
    fi
    case "$choice" in
      1) POOL="qli"; return ;;
      2) POOL="jetski"; return ;;
      3) POOL="minerlab"; return ;;
      0) exit 0 ;;
      *) err "$(msg '请输入 0-3。' 'Please enter 0-3.')" ;;
    esac
  done
}

prepare_qli() {
  POOL_NAME="QLI"
  PROFILE_FAMILY="qli-client"
  PROFILE_MODE="download-config"
  INSTALL_DIR="$MINERS_DIR/qli"
  CONFIG_PATH="$INSTALL_DIR/appsettings.json"
  LOG_PATH="$INSTALL_DIR/qli.log"
  MINER_BINARY_PATH="$INSTALL_DIR/qli-Client"
  STATE_PATH="$INSTALL_DIR/.miner-install.state"
  STOP_CMD="$(script_stop_hint qli)"
  validate_arg_count "$([[ -n "$FLAG_IGNORE_THREADS" ]] && echo 2 || echo 3)" \
    "qli <threads> <accessToken|qubicAddress> [alias]"

  local raw_threads="" token="" alias=""
  local qli_pps="" qli_cpu="" qli_gpu="" qli_gpu_version="" qli_gpu_cards="" qli_auto_update=""
  local qli_use_avx2="$FLAG_USE_AVX2"
  if [[ -n "$FLAG_IGNORE_THREADS" ]]; then
    token="${POOL_ARGS[0]:-}"
    alias="${POOL_ARGS[1]:-}"
  else
    raw_threads="${POOL_ARGS[0]:-}"
    token="${POOL_ARGS[1]:-}"
    alias="${POOL_ARGS[2]:-}"
  fi

  if [[ -z "$POOL" || "${#POOL_ARGS[@]}" -eq 0 ]]; then
    raw_threads=""
    token=""
    alias=""
  fi

  if [[ -z "$token" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'accessToken 或 qubicAddress' 'accessToken or qubicAddress')" token "" 1
  fi
  if [[ -z "$alias" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'miner 名称' 'miner alias')" alias "$(default_worker)" 0
  fi

  token="$(trim "${token:-${QLI_ACCESS_TOKEN:-${QLI_QUBIC_ADDRESS:-${QLI_PAYOUT_ID:-}}}}")"
  raw_threads="${raw_threads:-$INPUT_THREADS}"
  alias="${alias:-${QLI_ALIAS:-$(default_worker)}}"

  if [[ -z "$token" ]]; then
    err "$(msg 'QLI 需要 accessToken 或 qubicAddress。' 'QLI requires accessToken or qubicAddress.')"
    exit 1
  fi

  qli_pps="$FLAG_PPS"
  if [[ -z "$qli_pps" && -n "${QLI_PPS:-}" ]]; then
    assign_bool qli_pps QLI_PPS "$QLI_PPS"
  fi
  qli_cpu="$FLAG_CPU"
  if [[ -z "$qli_cpu" && -n "${QLI_CPU:-}" ]]; then
    assign_bool qli_cpu QLI_CPU "$QLI_CPU"
  fi
  qli_gpu="$FLAG_GPU"
  if [[ -z "$qli_gpu" && -n "${QLI_GPU:-}" ]]; then
    assign_bool qli_gpu QLI_GPU "$QLI_GPU"
  fi
  qli_gpu_version="${FLAG_GPU_VERSION:-${QLI_GPU_VERSION:-}}"
  qli_gpu_cards="${FLAG_GPU_CARDS:-${QLI_GPU_CARDS:-}}"
  qli_auto_update="$FLAG_AUTO_UPDATE"
  if [[ -z "$qli_auto_update" && -n "${QLI_AUTO_UPDATE:-}" ]]; then
    assign_bool qli_auto_update QLI_AUTO_UPDATE "$QLI_AUTO_UPDATE"
  fi
  if [[ "$qli_use_avx2" != "1" && -n "${QLI_USE_AVX2:-}" ]]; then
    assign_bool qli_use_avx2 QLI_USE_AVX2 "$QLI_USE_AVX2"
  fi

  if [[ "$AUTO_YES" -eq 0 && ( "$PARAM_MODE" -eq 0 || "${#POOL_ARGS[@]}" -eq 0 ) ]]; then
    if [[ -z "$qli_pps" ]]; then
      ask_yes_no "$(msg '使用 QLI PPS 模式?' 'Use QLI PPS mode?')" 1 && qli_pps=1 || qli_pps=0
    fi
    if [[ -z "$qli_cpu" ]]; then
      ask_yes_no "$(msg '启用 QLI CPU trainer?' 'Enable QLI CPU trainer?')" 1 && qli_cpu=1 || qli_cpu=0
    fi
    if [[ "$qli_cpu" == "1" && "$qli_use_avx2" != "1" ]]; then
      ask_yes_no "$(msg 'QLI CPU 使用 AVX2 版本?（不确定请选择否，使用自动模式）' 'Use QLI AVX2 CPU version? (choose no for auto detection)')" 0 \
        && qli_use_avx2=1 || qli_use_avx2=0
    fi
    if [[ -z "$qli_gpu" ]]; then
      ask_yes_no "$(msg '启用 QLI GPU trainer?' 'Enable QLI GPU trainer?')" 0 && qli_gpu=1 || qli_gpu=0
    fi
    if [[ "$qli_gpu" == "1" && -z "$qli_gpu_version" ]]; then
      ask "$(msg 'QLI GPU version，留空=自动，CUDA/AMD' 'QLI GPU version, empty=auto, CUDA/AMD')" qli_gpu_version "" 0
    fi
    if [[ "$qli_gpu" == "1" && -z "$qli_gpu_cards" ]]; then
      ask "$(msg 'QLI GPU cards，留空=全部自动，例如 0,-1' 'QLI GPU cards, empty=auto all, e.g. 0,-1')" qli_gpu_cards "" 0
    fi
    if [[ -z "$qli_auto_update" ]]; then
      ask_yes_no "$(msg '启用 QLI autoUpdate?' 'Enable QLI autoUpdate?')" 0 && qli_auto_update=1 || qli_auto_update=0
    fi
  fi

  qli_pps="${qli_pps:-1}"
  qli_cpu="${qli_cpu:-1}"
  qli_gpu="${qli_gpu:-0}"
  qli_gpu_version="${qli_gpu_version^^}"

  token="$(trim "$token")"
  alias="$(trim "$alias")"
  qli_gpu_cards="$(trim "$qli_gpu_cards")"
  reject_control_chars "QLI alias" "$alias"
  if [[ -z "$alias" ]]; then
    err "$(msg 'QLI miner 名称不能为空。' 'QLI miner alias is required.')"
    exit 1
  fi

  if [[ "$qli_pps" != "0" && "$qli_pps" != "1" ]]; then
    err "$(msg 'QLI_PPS 必须是 true/false 或 1/0。' 'QLI_PPS must be true/false or 1/0.')"
    exit 1
  fi
  if [[ "$qli_cpu" != "0" && "$qli_cpu" != "1" ]]; then
    err "$(msg 'QLI_CPU 必须是 true/false 或 1/0。' 'QLI_CPU must be true/false or 1/0.')"
    exit 1
  fi
  if [[ "$qli_gpu" != "0" && "$qli_gpu" != "1" ]]; then
    err "$(msg 'QLI_GPU 必须是 true/false 或 1/0。' 'QLI_GPU must be true/false or 1/0.')"
    exit 1
  fi
  if [[ -n "$qli_auto_update" && "$qli_auto_update" != "0" && "$qli_auto_update" != "1" ]]; then
    err "$(msg 'QLI_AUTO_UPDATE 必须是 true/false 或 1/0。' 'QLI_AUTO_UPDATE must be true/false or 1/0.')"
    exit 1
  fi
  if [[ "$qli_cpu" == "0" && "$qli_gpu" == "0" ]]; then
    if [[ "$AUTO_YES" -eq 1 || "$PARAM_MODE" -eq 1 ]]; then
      err "$(msg 'QLI 不能同时关闭 CPU 和 GPU trainer。' 'QLI cannot disable both CPU and GPU trainer.')"
      exit 1
    fi
    if ! ask_yes_no "$(msg 'CPU 和 GPU trainer 都关闭，仍然继续?' 'CPU and GPU trainer are both disabled. Continue?')" 0; then
      exit 1
    fi
  fi
  if [[ -n "$qli_gpu_version" && ! "$qli_gpu_version" =~ ^(CUDA|AMD)$ ]]; then
    err "$(msg 'QLI GPU version 目前只接受 CUDA 或 AMD。' 'QLI GPU version currently accepts CUDA or AMD only.')"
    exit 1
  fi
  if [[ -n "$qli_gpu_cards" ]] && ! validate_gpu_cards "$qli_gpu_cards"; then
    err "$(msg 'QLI gpu-cards 每项只能是 -1 或非负 GPU index，例如 -1,-1,0。' 'Each QLI gpu-cards item must be -1 or a non-negative GPU index, e.g. -1,-1,0.')"
    exit 1
  fi
  if [[ "$qli_gpu" == "0" && ( -n "$qli_gpu_version" || -n "$qli_gpu_cards" ) ]]; then
    err "$(msg 'QLI 已关闭 GPU，不能同时设置 gpu-version/gpu-cards。' 'QLI GPU is disabled; gpu-version/gpu-cards cannot be set.')"
    exit 1
  fi
  if [[ "$qli_cpu" == "0" && "$qli_use_avx2" == "1" ]]; then
    err "$(msg 'QLI 已关闭 CPU，不能同时设置 --use-avx2。' 'QLI CPU is disabled; --use-avx2 cannot be used.')"
    exit 1
  fi

  if [[ "$qli_cpu" == "1" ]]; then
    if [[ -z "$raw_threads" && -z "$FLAG_IGNORE_THREADS" && "$AUTO_YES" -eq 0 ]]; then
      ask "$(msg 'CPU 线程数，0=自动' 'CPU threads, 0=auto')" raw_threads "0" 0
    fi
    set_threads "$raw_threads" "$FLAG_IGNORE_THREADS"
  else
    if [[ -n "$FLAG_IGNORE_THREADS" ]]; then
      err "$(msg 'QLI 已关闭 CPU，不能同时设置 --ignore-threads。' 'QLI CPU is disabled; --ignore-threads cannot be used.')"
      exit 1
    fi
    THREADS="0"
    THREAD_MODE="disabled"
    if [[ -n "$raw_threads" && "$raw_threads" != "0" ]]; then
      add_action "CPU trainer 已关闭，忽略线程输入: $raw_threads" "Threads input ignored because CPU trainer is disabled: $raw_threads"
    fi
  fi
  WORKER_NAME="$alias"
  local token_key access_json cpu_version_json="" gpu_version_json="" gpu_cards_json=""
  if [[ "$token" == *.*.* ]]; then
    if ! validate_jwt "$token"; then
      err "$(msg 'QLI accessToken 看起来不像有效 JWT，应为 xxx.yyy.zzz。' 'QLI accessToken does not look like a valid JWT; expected xxx.yyy.zzz.')"
      exit 1
    fi
    validate_jwt_time "$token" "QLI accessToken" || exit 1
    token_key="accessToken"
    access_json="\"accessToken\": \"$(json_escape "$token")\",
    \"qubicAddress\": null"
  else
    if ! validate_qli_payout_id "$token"; then
      err "$(msg 'QLI qubicAddress 必须是 60 位大写字母。' 'QLI qubicAddress must be exactly 60 uppercase letters.')"
      exit 1
    fi
    token_key="qubicAddress"
    access_json="\"accessToken\": null,
    \"qubicAddress\": \"$(json_escape "$token")\""
  fi

  if [[ "$qli_use_avx2" == "1" ]]; then
    cpu_version_json="AVX2"
  fi
  if [[ -n "$qli_gpu_version" ]]; then
    gpu_version_json="$(json_escape "$qli_gpu_version")"
  fi
  if [[ -n "$qli_gpu_cards" ]]; then
    gpu_cards_json=",
      \"gpuCards\": \"$(json_escape "$qli_gpu_cards")\""
  fi

  local pps_json="true" cpu_json="true" gpu_json="false" auto_update_json=""
  [[ "$qli_pps" == "0" ]] && pps_json="false"
  [[ "$qli_cpu" == "0" ]] && cpu_json="false"
  [[ "$qli_gpu" == "1" ]] && gpu_json="true"
  if [[ "$qli_auto_update" == "1" ]]; then
    auto_update_json=",
    \"autoUpdate\": true"
  elif [[ "$qli_auto_update" == "0" ]]; then
    auto_update_json=",
    \"autoUpdate\": false"
  fi

  CONFIG_CONTENT="{
  \"ClientSettings\": {
    \"poolAddress\": \"wss://wps.qubic.li/ws\",
    \"alias\": \"$(json_escape "$alias")\",
    \"trainer\": {
      \"cpu\": $cpu_json,
      \"gpu\": $gpu_json,
      \"gpuVersion\": \"$gpu_version_json\",
      \"cpuVersion\": \"$cpu_version_json\",
      \"cpuThreads\": $THREADS$gpu_cards_json
    },
    \"pps\": $pps_json,
    $access_json,
    \"idling\": null$auto_update_json
  }
}"

  # Resolve release metadata only after all local inputs have passed validation.
  local qli_url qli_digest
  if ! qli_url="$(qli_latest_url)"; then
    warn "$(msg 'QLI 版本检查失败，将使用内置且已固定 SHA-256 的 3.8.10 下载地址。' 'QLI version check failed; using the built-in 3.8.10 URL with a pinned SHA-256.')"
    add_action "QLI 版本检查失败，降级到已固定 hash 的 3.8.10" "QLI version check failed; fall back to hash-pinned 3.8.10"
  fi
  DOWNLOAD_URLS=("$qli_url")
  qli_digest="$(expected_archive_sha256 "$qli_url" || true)"
  if [[ -n "$qli_digest" ]]; then
    set_download_trust "$qli_url" "$qli_digest" "installer pinned SHA-256"
  fi

  START_ARGS=("$MINER_BINARY_PATH")
  set_command_displays

  add_action "身份字段: $token_key" "Identity field: $token_key"
  if [[ "$qli_pps" == "1" ]]; then
    add_action "矿池模式: PPS" "Pool mode: PPS"
  else
    add_action "矿池模式: SOLO" "Pool mode: SOLO"
  fi
  add_action "CPU 训练器: $(switch_label "$qli_cpu" zh)" "CPU trainer: $(switch_label "$qli_cpu" en)"
  add_action "GPU 训练器: $(switch_label "$qli_gpu" zh)" "GPU trainer: $(switch_label "$qli_gpu" en)"
  [[ -n "$qli_gpu_version" ]] && add_action "GPU 版本: $qli_gpu_version" "GPU version: $qli_gpu_version"
  [[ -n "$qli_gpu_cards" ]] && add_action "GPU cards: $qli_gpu_cards" "GPU cards: $qli_gpu_cards"
  [[ -n "$cpu_version_json" ]] && add_action "CPU 版本: AVX2" "CPU version: AVX2"
  if [[ "$qli_auto_update" == "1" ]]; then
    add_action "自动更新: 开启" "autoUpdate: true"
  elif [[ "$qli_auto_update" == "0" ]]; then
    add_action "自动更新: 关闭" "autoUpdate: false"
  else
    add_action "自动更新: 不写入配置" "autoUpdate: omitted"
  fi
  add_risk "QLI 客户端运行时可能按任务下载 trainer worker；本安装器不会提前执行这些 worker。" "The QLI client may download trainer workers at runtime; this installer does not execute them in advance."
}

prepare_jetski() {
  POOL_NAME="JetSki"
  PROFILE_FAMILY="jetski"
  PROFILE_MODE="download-flags"
  INSTALL_DIR="$MINERS_DIR/jetski"
  CONFIG_PATH="$INSTALL_DIR/appsettings.json"
  LOG_PATH="$INSTALL_DIR/jetski.log"
  MINER_BINARY_PATH="$INSTALL_DIR/qubjetski-Client"
  STATE_PATH="$INSTALL_DIR/.miner-install.state"
  STOP_CMD="$(script_stop_hint jetski)"
  validate_arg_count 3 "jetski <wallet> [workername] [CPU threads]"

  local wallet="" worker="" raw_threads=""
  local jetski_mode="${JETSKI_MODE:-pplns}"
  local jetski_mode_explicit=0
  local gpu_version="${FLAG_GPU_VERSION:-${JETSKI_GPU_VERSION:-}}"
  local gpu_cards="${FLAG_GPU_CARDS:-${JETSKI_GPU_CARDS:-}}"

  if [[ "$PARAM_MODE" -eq 1 || "$AUTO_YES" -eq 1 ]]; then
    wallet="${POOL_ARGS[0]:-${JETSKI_WALLET:-}}"
    worker="${POOL_ARGS[1]:-${JETSKI_WORKER:-$(default_worker)}}"
    raw_threads="${POOL_ARGS[2]:-$INPUT_THREADS}"
  fi

  if [[ -n "${JETSKI_PPLNS:-}" ]]; then
    local jetski_pplns_value
    if ! jetski_pplns_value="$(bool_value "$JETSKI_PPLNS")"; then
      err "$(msg 'JETSKI_PPLNS 必须是 true/false 或 1/0。' 'JETSKI_PPLNS must be true/false or 1/0.')"
      exit 1
    fi
    jetski_mode_explicit=1
    if [[ "$jetski_pplns_value" == "1" ]]; then
      jetski_mode="pplns"
    else
      jetski_mode="solo"
    fi
  fi
  if [[ -z "$FLAG_CPU" && -n "${JETSKI_CPU:-}" ]]; then
    assign_bool FLAG_CPU JETSKI_CPU "$JETSKI_CPU"
  fi
  if [[ -z "$FLAG_GPU" && -n "${JETSKI_GPU:-}" ]]; then
    assign_bool FLAG_GPU JETSKI_GPU "$JETSKI_GPU"
  fi
  if [[ "$FLAG_PPLNS" -eq 1 && "$FLAG_PPS" == "0" ]]; then
    err "$(msg 'JetSki 不能同时指定 --pplns 和 --solo。' 'JetSki cannot use --pplns and --solo together.')"
    exit 1
  fi
  if [[ "$FLAG_PPS" == "1" ]]; then
    err "$(msg 'JetSki 使用 --pplns，不使用 --pps。' 'JetSki uses --pplns, not --pps.')"
    exit 1
  fi
  if [[ "$FLAG_PPS" == "0" ]]; then
    jetski_mode="solo"
    jetski_mode_explicit=1
  elif [[ "$FLAG_PPLNS" -eq 1 ]]; then
    jetski_mode="pplns"
    jetski_mode_explicit=1
  fi
  jetski_mode="${jetski_mode,,}"
  case "$jetski_mode" in
    pplns|solo) ;;
    *)
      err "$(msg 'JETSKI_MODE 必须是 pplns 或 solo。' 'JETSKI_MODE must be pplns or solo.')"
      exit 1
      ;;
  esac

  if [[ -z "$wallet" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'JetSki wallet 地址' 'JetSki wallet address')" wallet "" 1
  fi
  if [[ -z "$worker" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'worker 名称，需保持唯一' 'worker name, must be unique')" worker "$(default_worker)" 0
  fi
  if [[ "$AUTO_YES" -eq 0 && "$jetski_mode_explicit" -eq 0 ]]; then
    if ask_yes_no "$(msg '使用 JetSki PPLNS 模式?' 'Use JetSki PPLNS mode?')" 1; then
      jetski_mode="pplns"
    else
      jetski_mode="solo"
    fi
  fi

  wallet="$(trim "$wallet")"
  worker="$(trim "$worker")"
  raw_threads="$(trim "$raw_threads")"
  gpu_version="$(trim "$gpu_version")"
  gpu_cards="$(trim "$gpu_cards")"

  if [[ -z "$wallet" ]]; then
    err "$(msg 'JetSki 需要 wallet。' 'JetSki requires wallet.')"
    exit 1
  fi
  if [[ -z "$worker" ]]; then
    err "$(msg 'JetSki 需要 worker 名称。' 'JetSki requires worker name.')"
    exit 1
  fi
  if ! validate_qli_payout_id "$wallet"; then
    err "$(msg 'JetSki wallet 必须是 60 位大写字母的 Qubic 地址。' 'JetSki wallet must be a 60-letter uppercase Qubic address.')"
    exit 1
  fi
  reject_control_chars "JetSki worker" "$worker"
  if [[ ! "$worker" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    err "$(msg 'JetSki worker 只能包含字母、数字、点、下划线和短横线，最长 64 位。' 'JetSki worker may contain letters, numbers, dot, underscore, and dash only; max 64 characters.')"
    exit 1
  fi

  if [[ -z "$FLAG_CPU" && "$AUTO_YES" -eq 0 ]]; then
    ask_yes_no "$(msg '启用 CPU?' 'Enable CPU?')" 1 && FLAG_CPU=1 || FLAG_CPU=0
  fi
  if [[ -z "$FLAG_GPU" && "$AUTO_YES" -eq 0 ]]; then
    ask_yes_no "$(msg '启用 GPU?' 'Enable GPU?')" 0 && FLAG_GPU=1 || FLAG_GPU=0
  fi
  FLAG_CPU="${FLAG_CPU:-1}"
  FLAG_GPU="${FLAG_GPU:-0}"

  if [[ "$FLAG_CPU" != "0" && "$FLAG_CPU" != "1" ]]; then
    err "$(msg 'JetSki CPU 选项必须是 true/false 或 1/0。' 'JetSki CPU option must be true/false or 1/0.')"
    exit 1
  fi
  if [[ "$FLAG_GPU" != "0" && "$FLAG_GPU" != "1" ]]; then
    err "$(msg 'JetSki GPU 选项必须是 true/false 或 1/0。' 'JetSki GPU option must be true/false or 1/0.')"
    exit 1
  fi

  if [[ "$FLAG_CPU" == "1" && -z "$raw_threads" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'CPU 线程数，0=自动' 'CPU threads, 0=auto')" raw_threads "0" 0
  fi
  if [[ "$FLAG_GPU" == "1" && -z "$gpu_version" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'JetSki GPU version，留空=客户端默认，CUDA/AMD' 'JetSki GPU version, empty=client default, CUDA/AMD')" gpu_version "" 0
  fi
  if [[ "$FLAG_GPU" == "1" && -z "$gpu_cards" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'JetSki GPU cards，留空=客户端默认，例如 -1,-1,0' 'JetSki GPU cards, empty=client default, e.g. -1,-1,0')" gpu_cards "" 0
  fi

  raw_threads="$(trim "$raw_threads")"
  gpu_version="$(trim "$gpu_version")"
  gpu_cards="$(trim "$gpu_cards")"

  if [[ "$FLAG_CPU" == "0" && "$FLAG_GPU" == "0" ]]; then
    if [[ "$AUTO_YES" -eq 1 ]]; then
      err "$(msg 'JetSki 不能在 --yes 模式下同时关闭 CPU 和 GPU。' 'JetSki cannot disable both CPU and GPU in --yes mode.')"
      exit 1
    fi
    if ! ask_yes_no "$(msg 'CPU 和 GPU 都关闭，仍然继续?' 'CPU and GPU are both disabled. Continue?')" 0; then
      exit 1
    fi
  fi

  if [[ -n "$gpu_version" ]]; then
    gpu_version="${gpu_version^^}"
    if [[ "$gpu_version" != "CUDA" && "$gpu_version" != "AMD" ]]; then
      err "$(msg 'JetSki gpu-version 必须是 CUDA 或 AMD。' 'JetSki gpu-version must be CUDA or AMD.')"
      exit 1
    fi
  fi
  if [[ -n "$gpu_cards" ]] && ! validate_gpu_cards "$gpu_cards"; then
    err "$(msg 'JetSki gpu-cards 每项只能是 -1 或非负 GPU index，例如 -1,-1,0。' 'Each JetSki gpu-cards item must be -1 or a non-negative GPU index, e.g. -1,-1,0.')"
    exit 1
  fi
  if [[ "$FLAG_GPU" == "0" && ( -n "$gpu_version" || -n "$gpu_cards" ) ]]; then
    err "$(msg 'JetSki 已关闭 GPU，不能同时设置 gpu-version/gpu-cards。' 'JetSki GPU is disabled; gpu-version/gpu-cards cannot be set.')"
    exit 1
  fi

  if [[ "$FLAG_CPU" == "1" ]]; then
    set_threads "$raw_threads" "$FLAG_IGNORE_THREADS"
  else
    if [[ -n "$FLAG_IGNORE_THREADS" ]]; then
      err "$(msg 'JetSki 已关闭 CPU，不能同时设置 --ignore-threads。' 'JetSki CPU is disabled; --ignore-threads cannot be used.')"
      exit 1
    fi
    THREADS="0"
    THREAD_MODE="disabled"
    if [[ -n "$raw_threads" ]]; then
      add_action "CPU 已关闭，忽略线程输入: $raw_threads" "Threads input ignored because CPU is disabled: $raw_threads"
    fi
  fi
  WORKER_NAME="$worker"
  JETSKI_ARCHIVE_NAME="qubjetski.PPLNS-latest.tar.gz"
  if [[ "$jetski_mode" == "solo" ]]; then
    JETSKI_ARCHIVE_NAME="qubjetski-latest.tar.gz"
  fi
  DOWNLOAD_URLS=("$(jetski_latest_url "$jetski_mode")")
  local jetski_digest jetski_hash_digest jetski_pinned_digest
  jetski_digest="$(github_release_asset_sha256 "${DOWNLOAD_URLS[0]}" || true)"
  if [[ -n "$jetski_digest" ]]; then
    set_download_trust "${DOWNLOAD_URLS[0]}" "$jetski_digest" "GitHub release digest"
  else
    jetski_hash_digest="$(jetski_release_sha256 "$jetski_mode" || true)"
    if [[ -n "$jetski_hash_digest" ]]; then
      set_download_trust "${DOWNLOAD_URLS[0]}" "$jetski_hash_digest" "JetSki official .hash"
    else
      jetski_pinned_digest="$(expected_archive_sha256 "${DOWNLOAD_URLS[0]}" || true)"
      if [[ -n "$jetski_pinned_digest" ]]; then
        set_download_trust "${DOWNLOAD_URLS[0]}" "$jetski_pinned_digest" "installer pinned SHA-256"
      else
        warn "$(msg 'JetSki 未提供可读取的远端 hash，将使用官方 GitHub Release 地址并记录本地 SHA-256。' 'No readable JetSki remote hash is available; the official GitHub Release URL will be used and a local SHA-256 will be recorded.')"
      fi
    fi
  fi

  local args=("-wallet" "$wallet" "-workername" "$worker")
  [[ "$FLAG_CPU" == "1" ]] && args+=("-cpu" "-threads" "$THREADS")
  [[ "$FLAG_GPU" == "1" ]] && args+=("-gpu")
  [[ -n "$gpu_version" ]] && args+=("-gpu-version" "$gpu_version")
  [[ -n "$gpu_cards" ]] && args+=("-gpu-cards" "$gpu_cards")
  [[ "$jetski_mode" == "pplns" ]] && args+=("-pplns")

  SETUP_ARGS=("$MINER_BINARY_PATH" "${args[@]}")
  START_ARGS=("$MINER_BINARY_PATH" "-start")
  set_command_displays
  add_action "通过 qubjetski-Client 生成配置" "Generate config through qubjetski-Client"
  add_action "在 staging 中生成并验证，成功后再备份和提交配置" "Generate and validate in staging, then back up and commit only after success"
  add_action "CPU: $(switch_label "$FLAG_CPU" zh)" "CPU: $(switch_label "$FLAG_CPU" en)"
  add_action "GPU: $(switch_label "$FLAG_GPU" zh)" "GPU: $(switch_label "$FLAG_GPU" en)"
  [[ -n "$gpu_version" ]] && add_action "GPU 版本: $gpu_version" "GPU version: $gpu_version"
  [[ -n "$gpu_cards" ]] && add_action "GPU cards: $gpu_cards" "GPU cards: $gpu_cards"
  if [[ "$jetski_mode" == "pplns" ]]; then
    add_action "矿池模式: PPLNS" "Pool mode: PPLNS"
  else
    add_action "矿池模式: SOLO" "Pool mode: SOLO"
  fi
  add_risk "JetSki 客户端运行时可能下载对应 epoch 的 CPU/GPU worker；本安装器会先验证启用状态。" "JetSki may download epoch-specific CPU/GPU workers at runtime; the installer validates enabled devices first."
}

load_minerlab_release() {
  local hash_url="https://dl.minerlab.io/miners/QLAB.Z.hash"
  local archive_url="https://dl.minerlab.io/miners/QLAB.Z.tar.gz"
  local payload archive_sha version binary_sha

  payload="$(curl -fsSL --connect-timeout 8 --max-time 20 --max-filesize 4096 \
    "$hash_url" 2>/dev/null || true)"
  archive_sha="$(printf '%s\n' "$payload" | awk -F: '$1 == "sha256" {gsub(/[[:space:]]/, "", $2); print tolower($2); exit}')"
  version="$(printf '%s\n' "$payload" | awk -F: '$1 == "version" {gsub(/[[:space:]]/, "", $2); print $2; exit}')"
  binary_sha="$(printf '%s\n' "$payload" | awk -F: '$1 == "linux_sha256" {gsub(/[[:space:]]/, "", $2); print tolower($2); exit}')"

  if [[ ! "$archive_sha" =~ ^[0-9a-f]{64}$ || ! "$binary_sha" =~ ^[0-9a-f]{64}$ \
    || ! "$version" =~ ^[A-Za-z0-9._-]+$ ]]; then
    err "$(msg '无法从 Minerlab 官方 hash 服务读取有效的 QLAB.Z 发布信息。' 'Could not read valid QLAB.Z release metadata from the official Minerlab hash service.')"
    exit 1
  fi

  MINERLAB_RELEASE_VERSION="$version"
  MINERLAB_BINARY_SHA256="$binary_sha"
  DOWNLOAD_URLS=("$archive_url")
  set_download_trust "$archive_url" "$archive_sha" "Minerlab official QLAB.Z.hash"
}

prepare_minerlab() {
  POOL_NAME="Minerlab"
  PROFILE_FAMILY="minerlab-qlab"
  PROFILE_MODE="download-config"
  INSTALL_DIR="$MINERS_DIR/minerlab"
  CONFIG_PATH="$INSTALL_DIR/appsettings.json"
  LOG_PATH="$INSTALL_DIR/minerlab.log"
  MINER_BINARY_PATH="$INSTALL_DIR/qlab-miner"
  STATE_PATH="$INSTALL_DIR/.miner-install.state"
  STOP_CMD="$(script_stop_hint minerlab)"
  validate_arg_count 3 "minerlab <username> [CPU threads] [alias]"

  local username="" raw_threads="" worker=""
  local minerlab_cpu="$FLAG_CPU"
  local minerlab_gpu="$FLAG_GPU"
  local minerlab_gpu_version="${FLAG_GPU_VERSION:-${MINERLAB_GPU_VERSION:-}}"
  local minerlab_gpu_cards="${FLAG_GPU_CARDS:-${MINERLAB_GPU_CARDS:-}}"
  local minerlab_use_avx2="$FLAG_USE_AVX2"

  if [[ "$PARAM_MODE" -eq 1 || "$AUTO_YES" -eq 1 ]]; then
    username="${POOL_ARGS[0]:-${MINERLAB_USERNAME:-}}"
    raw_threads="${POOL_ARGS[1]:-$INPUT_THREADS}"
    worker="${POOL_ARGS[2]:-${MINERLAB_WORKER:-$(default_worker)}}"
  fi
  if [[ -z "$minerlab_cpu" && -n "${MINERLAB_CPU:-}" ]]; then
    assign_bool minerlab_cpu MINERLAB_CPU "$MINERLAB_CPU"
  fi
  if [[ -z "$minerlab_gpu" && -n "${MINERLAB_GPU:-}" ]]; then
    assign_bool minerlab_gpu MINERLAB_GPU "$MINERLAB_GPU"
  fi
  if [[ "$minerlab_use_avx2" != "1" && -n "${MINERLAB_USE_AVX2:-}" ]]; then
    assign_bool minerlab_use_avx2 MINERLAB_USE_AVX2 "$MINERLAB_USE_AVX2"
  fi

  if [[ -z "$username" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'Minerlab username' 'Minerlab username')" username "" 1
  fi
  if [[ -z "$worker" && "$AUTO_YES" -eq 0 ]]; then
    ask "$(msg 'miner 名称' 'miner alias')" worker "${MINERLAB_WORKER:-$(default_worker)}" 0
  fi
  if [[ "$AUTO_YES" -eq 0 && ( "$PARAM_MODE" -eq 0 || "${#POOL_ARGS[@]}" -eq 0 ) ]]; then
    if [[ -z "$minerlab_cpu" ]]; then
      ask_yes_no "$(msg '启用 Minerlab CPU miner?' 'Enable Minerlab CPU miner?')" 0 && minerlab_cpu=1 || minerlab_cpu=0
    fi
    if [[ "$minerlab_cpu" == "1" && "$minerlab_use_avx2" != "1" ]]; then
      ask_yes_no "$(msg 'Minerlab CPU 使用 AVX2 版本?（不确定请选择否，使用自动模式）' 'Use Minerlab AVX2 CPU version? (choose no for auto detection)')" 0 \
        && minerlab_use_avx2=1 || minerlab_use_avx2=0
    fi
    if [[ -z "$minerlab_gpu" ]]; then
      ask_yes_no "$(msg '启用 Minerlab GPU miner?' 'Enable Minerlab GPU miner?')" 1 && minerlab_gpu=1 || minerlab_gpu=0
    fi
    if [[ "$minerlab_gpu" == "1" && -z "$minerlab_gpu_version" ]]; then
      ask "$(msg 'Minerlab GPU version，留空=CUDA，CUDA/AMD' 'Minerlab GPU version, empty=CUDA, CUDA/AMD')" minerlab_gpu_version "" 0
    fi
    if [[ "$minerlab_gpu" == "1" && -z "$minerlab_gpu_cards" ]]; then
      ask "$(msg 'Minerlab GPU cards，留空=all，例如 0,-1' 'Minerlab GPU cards, empty=all, e.g. 0,-1')" minerlab_gpu_cards "" 0
    fi
  fi

  minerlab_cpu="${minerlab_cpu:-0}"
  minerlab_gpu="${minerlab_gpu:-1}"
  username="$(trim "$username")"
  raw_threads="$(trim "$raw_threads")"
  worker="$(trim "${worker:-${MINERLAB_WORKER:-$(default_worker)}}")"
  minerlab_gpu_version="$(trim "$minerlab_gpu_version")"
  minerlab_gpu_cards="$(trim "$minerlab_gpu_cards")"

  if [[ "$minerlab_cpu" == "0" && "${#POOL_ARGS[@]}" -eq 2 && -n "$raw_threads" && ! "$raw_threads" =~ ^[0-9]+$ ]]; then
    worker="$raw_threads"
    raw_threads=""
    add_action "CPU miner 已关闭，第二个位置参数按矿工名处理" "Second positional argument treated as worker because CPU mining is disabled"
  fi
  if [[ -z "$username" ]]; then
    err "$(msg 'Minerlab 需要 username。' 'Minerlab requires username.')"
    exit 1
  fi
  if [[ ! "$username" =~ ^[A-Za-z0-9._@-]{1,128}$ ]]; then
    err "$(msg 'Minerlab username 只能包含字母、数字、点、下划线、@ 和短横线，最长 128 位。' 'Minerlab username may contain letters, numbers, dot, underscore, @, and dash only; max 128 characters.')"
    exit 1
  fi
  if [[ -z "$worker" || ! "$worker" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    err "$(msg 'Minerlab worker 只能包含字母、数字、点、下划线和短横线，最长 64 位。' 'Minerlab worker may contain letters, numbers, dot, underscore, and dash only; max 64 characters.')"
    exit 1
  fi
  if [[ "$minerlab_cpu" != "0" && "$minerlab_cpu" != "1" ]]; then
    err "$(msg 'MINERLAB_CPU 必须是 true/false 或 1/0。' 'MINERLAB_CPU must be true/false or 1/0.')"
    exit 1
  fi
  if [[ "$minerlab_gpu" != "0" && "$minerlab_gpu" != "1" ]]; then
    err "$(msg 'MINERLAB_GPU 必须是 true/false 或 1/0。' 'MINERLAB_GPU must be true/false or 1/0.')"
    exit 1
  fi
  if [[ "$minerlab_cpu" == "0" && "$minerlab_gpu" == "0" ]]; then
    err "$(msg 'Minerlab 不能同时关闭 CPU 和 GPU。' 'Minerlab cannot disable both CPU and GPU.')"
    exit 1
  fi
  if [[ "$minerlab_gpu" == "0" && ( -n "$minerlab_gpu_version" || -n "$minerlab_gpu_cards" ) ]]; then
    err "$(msg 'Minerlab 已关闭 GPU，不能同时设置 gpu-version/gpu-cards。' 'Minerlab GPU is disabled; gpu-version/gpu-cards cannot be set.')"
    exit 1
  fi

  minerlab_gpu_version="${minerlab_gpu_version:-CUDA}"
  minerlab_gpu_version="${minerlab_gpu_version^^}"
  if [[ "$minerlab_gpu_version" != "CUDA" && "$minerlab_gpu_version" != "AMD" ]]; then
    err "$(msg 'Minerlab GPU version 目前只接受 CUDA 或 AMD。' 'Minerlab GPU version currently accepts CUDA or AMD only.')"
    exit 1
  fi
  if [[ "${minerlab_gpu_cards,,}" == "all" ]]; then
    minerlab_gpu_cards="all"
  elif [[ -n "$minerlab_gpu_cards" ]] && ! validate_gpu_cards "$minerlab_gpu_cards"; then
    err "$(msg 'Minerlab gpu-cards 必须是 all，或由 -1/非负整数组成，例如 -1,-1,0。' 'Minerlab gpu-cards must be all or a list of -1/non-negative integers, e.g. -1,-1,0.')"
    exit 1
  fi
  if [[ "$minerlab_cpu" == "0" && "$minerlab_use_avx2" == "1" ]]; then
    err "$(msg 'Minerlab 已关闭 CPU，不能同时设置 --use-avx2。' 'Minerlab CPU is disabled; --use-avx2 cannot be used.')"
    exit 1
  fi

  if [[ "$minerlab_cpu" == "1" ]]; then
    if [[ -z "$raw_threads" ]]; then
      local total default_threads
      total="$(cpu_count)"
      default_threads=$((total > 2 ? total - 2 : 1))
      if [[ "$AUTO_YES" -eq 0 ]]; then
        ask "$(msg 'CPU 线程数，0=自动' 'CPU threads, 0=auto')" raw_threads "$default_threads" 0
      else
        raw_threads="$default_threads"
      fi
    fi
    set_threads "$raw_threads" "$FLAG_IGNORE_THREADS"
  else
    if [[ -n "$FLAG_IGNORE_THREADS" ]]; then
      err "$(msg 'Minerlab 已关闭 CPU，不能同时设置 --ignore-threads。' 'Minerlab CPU is disabled; --ignore-threads cannot be used.')"
      exit 1
    fi
    THREADS="0"
    THREAD_MODE="disabled"
  fi

  local cpu_json="false" gpu_json="false" cpu_version="auto" gpu_cards="all"
  [[ "$minerlab_cpu" == "1" ]] && cpu_json="true"
  [[ "$minerlab_gpu" == "1" ]] && gpu_json="true"
  [[ "$minerlab_use_avx2" == "1" ]] && cpu_version="AVX2"
  [[ -n "$minerlab_gpu_cards" ]] && gpu_cards="$minerlab_gpu_cards"

  WORKER_NAME="$worker"
  load_minerlab_release
  CONFIG_CONTENT="{
  \"pool\": {
    \"url\": \"wss://qu-pool.minerlab.io/ws/$(json_escape "$username")\",
    \"wallet\": \"$(json_escape "$username")\",
    \"alias\": \"$(json_escape "$worker")\",
    \"pps\": false
  },
  \"miner\": {
    \"cpu\": {
      \"enabled\": $cpu_json,
      \"version\": \"$cpu_version\",
      \"threads\": $THREADS
    },
    \"gpu\": {
      \"enabled\": $gpu_json,
      \"version\": \"$(json_escape "$minerlab_gpu_version")\",
      \"cards\": \"$(json_escape "$gpu_cards")\"
    }
  },
  \"api\": {
    \"bind\": \"127.0.0.1:17899\"
  }
}"

  START_ARGS=("$MINER_BINARY_PATH" "-start")
  set_command_displays
  add_action "Minerlab 用户名: $username" "Minerlab username: $username"
  add_action "QLAB.Z 版本: $MINERLAB_RELEASE_VERSION" "QLAB.Z version: $MINERLAB_RELEASE_VERSION"
  if [[ "$minerlab_cpu" == "1" ]]; then
    add_action "CPU 矿工: 开启 ($cpu_version)" "CPU miner: on ($cpu_version)"
  else
    add_action "CPU 矿工: 关闭" "CPU miner: off"
  fi
  if [[ "$minerlab_gpu" == "1" ]]; then
    add_action "GPU 矿工: 开启 ($minerlab_gpu_version, $gpu_cards)" "GPU miner: on ($minerlab_gpu_version, $gpu_cards)"
  else
    add_action "GPU 矿工: 关闭" "GPU miner: off"
  fi
  add_action "矿池地址: wss://qu-pool.minerlab.io/ws/$username" "Pool address: wss://qu-pool.minerlab.io/ws/$username"
  add_action "上游 binary SHA-256: $MINERLAB_BINARY_SHA256" "Upstream binary SHA-256: $MINERLAB_BINARY_SHA256"
  add_action "适配方式: 仅安装 qlab-miner，不执行上游脚本或安装 systemd" "Adapter: install only qlab-miner; do not run the upstream script or install systemd"
  add_risk "首次运行后请在 Minerlab 面板核对 worker 和收益" "Verify the worker and rewards in the Minerlab dashboard after the first run"
  add_risk "qlab-miner 运行时可能下载 CPU/GPU worker；本安装器不会提前执行它们。" "qlab-miner may download CPU/GPU workers at runtime; this installer does not execute them in advance."
}

prepare_pool() {
  ACTION_SUMMARY=()
  RISK_SUMMARY=()
  DOWNLOAD_URLS=()
  SETUP_CMD=""
  START_CMD=""
  START_ARGS=()
  SETUP_ARGS=()
  MINER_BINARY_PATH=""
  STATE_PATH=""
  MINERLAB_RELEASE_VERSION=""
  MINERLAB_BINARY_SHA256=""
  DOWNLOAD_TRUST_URL=""
  DOWNLOAD_TRUST_SHA256=""
  DOWNLOAD_TRUST_SOURCE=""
  START_LOG_PATH=""
  START_LOG_OFFSET=0
  STARTUP_STATUS=""
  case "$POOL" in
    qli) prepare_qli ;;
    jetski) prepare_jetski ;;
    minerlab) prepare_minerlab ;;
    *) err "$(msg '未知矿池。' 'Unknown pool.')"; exit 1 ;;
  esac
}

print_summary() {
  section "$(msg '执行摘要' 'Execution summary')"
  echo "$(msg '矿池' 'Pool'): $POOL_NAME"
  echo "$(msg '安装目录' 'Install dir'): $INSTALL_DIR"
  echo "$(msg '配置文件' 'Config'): $CONFIG_PATH"
  echo "$(msg '日志文件' 'Log'): $LOG_PATH"
  echo "$(msg '矿工名' 'Worker'): $WORKER_NAME"
  echo "$(msg '线程' 'Threads'): $THREADS ($(thread_mode_label "$THREAD_MODE"))"
  echo "$(msg '下载' 'Downloads'):"
  local url
  if [[ "${#DOWNLOAD_URLS[@]}" -eq 0 ]]; then
    echo "  - $(msg '无，复用本地文件' 'None; reuse local files')"
  else
    for url in "${DOWNLOAD_URLS[@]}"; do
      echo "  - $url"
      echo "    $(msg '发布方参考' 'Publisher reference'): $(publisher_reference "$url")"
    done
  fi
  if [[ -n "$DOWNLOAD_TRUST_SHA256" ]]; then
    echo "$(msg '预期 SHA-256' 'Expected SHA-256'): $DOWNLOAD_TRUST_SHA256"
    echo "$(msg '校验来源' 'Verification source'): $DOWNLOAD_TRUST_SOURCE"
  elif [[ "${#DOWNLOAD_URLS[@]}" -gt 0 ]]; then
    echo "$(msg '下载信任' 'Download trust'): $(msg '矿池官方 HTTPS 白名单' 'official pool HTTPS allowlist')"
    echo "$(msg 'SHA-256 策略' 'SHA-256 policy'): $(msg '下载后记录，用于后续缓存完整性检查' 'record after download for later cache integrity checks')"
  fi
  echo "$(msg '配置与说明' 'Settings and notes'):"
  local item
  for item in "${ACTION_SUMMARY[@]}"; do
    echo "  - $item"
  done
  if [[ "${#RISK_SUMMARY[@]}" -gt 0 ]]; then
    echo "$(msg '风险' 'Risks'):"
    for item in "${RISK_SUMMARY[@]}"; do
      echo "  - $item"
    done
  fi
  echo "$(msg '启动命令' 'Start command'): $START_CMD"
  if [[ -n "$SETUP_CMD" ]]; then
    echo "$(msg '配置命令' 'Setup command'): $SETUP_CMD"
  fi
  echo "$(msg '停止命令' 'Stop command'): $STOP_CMD"
}

validate_download_url() {
  local url="$1"
  reject_control_chars "download URL" "$url"
  case "$url" in
    https://dl.qubic.li/downloads/qli-Client-*-Linux-x64.tar.gz|\
    https://dl.minerlab.io/miners/QLAB.Z.tar.gz|\
    https://github.com/jtskxx/JETSKI-QUBIC-POOL/releases/download/*)
      return 0
      ;;
  esac
  err "$(msg '拒绝未列入允许范围的下载地址:' 'Refusing download URL outside the allowlist:') $url"
  return 1
}

publisher_reference() {
  case "$1" in
    https://dl.qubic.li/downloads/*)
      printf '%s\n' 'https://github.com/qubic-li/client'
      ;;
    https://dl.minerlab.io/miners/*)
      printf '%s\n' 'https://dl.minerlab.io/qlab-install.sh'
      ;;
    https://github.com/jtskxx/JETSKI-QUBIC-POOL/releases/download/*)
      printf '%s\n' 'https://github.com/jtskxx/JETSKI-QUBIC-POOL'
      ;;
  esac
}

expected_archive_sha256() {
  if [[ -n "$DOWNLOAD_TRUST_URL" && "$1" == "$DOWNLOAD_TRUST_URL" \
    && "$DOWNLOAD_TRUST_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' "$DOWNLOAD_TRUST_SHA256"
    return 0
  fi
  case "$1" in
    *qli-Client-3.8.10-Linux-x64.tar.gz)
      printf '%s\n' "08385d75f1ab4861edaf8462c3c7aa4a6343c1d068a9bf6ea94c2096eae62113"
      ;;
    *qli-Client-3.7.0-Linux-x64.tar.gz)
      printf '%s\n' "e1ef242f2f77e20897576e5c05a88c0c4f1ecc5fa7ee97823b17fbb0ccef66c1"
      ;;
    *qli-Client-3.6.1-Linux-x64.tar.gz)
      printf '%s\n' "7e0cb8955421545feb51189fbe1ecc4ba20a1a3aaa4f0cf4f59031c0dc8a2fc6"
      ;;
    *qubjetski.PPLNS-latest.tar.gz)
      printf '%s\n' "ebc87c47e518d3d98ae26603fdae78c9b37dd47c678b30373f9939a9685d9328"
      ;;
    *qubjetski-latest.tar.gz)
      printf '%s\n' "807b264d60dcb6d02fdf128f195e4cf7e2cdfe5aa3e59906a109e8544cf16d2d"
      ;;
    *)
      return 1
      ;;
  esac
}

archive_is_safe() {
  local archive="$1"
  local listing verbose member line type size count=0 total=0
  listing="$(tar -tzf "$archive" 2>/dev/null)" || return 1
  [[ -n "$listing" ]] || return 1
  if printf '%s\n' "$listing" | LC_ALL=C sort | uniq -d | grep -q .; then
    return 1
  fi
  while IFS= read -r member; do
    case "$member" in
      /*|../*|*/../*|*/..)
        return 1
        ;;
    esac
  done <<< "$listing"
  verbose="$(LC_ALL=C tar --numeric-owner -tvzf "$archive" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    type="${line:0:1}"
    [[ "$type" == "-" || "$type" == "d" ]] || return 1
    size="$(awk '{print $3}' <<< "$line")"
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    count=$((count + 1))
    (( count <= MAX_ARCHIVE_ENTRIES )) || return 1
    (( size <= MAX_ARCHIVE_MEMBER_BYTES )) || return 1
    total=$((total + size))
    (( total <= MAX_ARCHIVE_TOTAL_BYTES )) || return 1
  done <<< "$verbose"
  (( count > 0 )) || return 1
  return 0
}

archive_integrity_ok() {
  local url="$1"
  local archive="$2"
  local expected actual recorded recorded_url
  archive_is_safe "$archive" || return 1
  actual="$(sha256sum "$archive" | awk '{print $1}')" || return 1
  expected="$(expected_archive_sha256 "$url" || true)"
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    return 1
  fi
  if [[ -z "$expected" ]]; then
    [[ -f "$archive.url" && -f "$archive.sha256" ]] || return 1
  fi
  if [[ -f "$archive.sha256" ]]; then
    recorded="$(awk 'NR == 1 {print $1}' "$archive.sha256" 2>/dev/null)"
    [[ "$recorded" == "$actual" ]] || return 1
  fi
  if [[ -f "$archive.url" ]]; then
    IFS= read -r recorded_url < "$archive.url" || return 1
    [[ "$recorded_url" == "$url" ]] || return 1
  fi
}

download_with_retries() {
  local url="$1"
  local output="$2"
  if command -v wget >/dev/null 2>&1; then
    local -a wget_args=(--https-only --timeout=30 --tries=3 --retry-connrefused)
    if [[ -t 2 ]]; then
      wget_args+=(--progress=bar:force:noscroll)
    else
      wget_args+=(--no-verbose)
    fi
    wget "${wget_args[@]}" -O "$output" "$url"
  else
    local -a curl_args=(-fL --show-error --proto '=https' --proto-redir '=https'
      --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600)
    if [[ -t 2 ]]; then
      curl_args+=(--progress-bar)
    else
      curl_args+=(--silent)
    fi
    curl "${curl_args[@]}" -o "$output" "$url"
  fi
}

download_archive() {
  local url="$1"
  local output="$2"
  local part actual expected hash_source sidecar_tmp url_tmp
  validate_download_url "$url" || exit 1
  if [[ -L "$output" || -L "$output.sha256" || -L "$output.url" ]]; then
    err "$(msg '拒绝使用符号链接形式的下载缓存或校验记录。' 'Refusing symlinked download cache or verification metadata.')"
    exit 1
  fi

  if [[ "$FORCE_DOWNLOAD" -eq 0 && -f "$output" ]] \
    && archive_integrity_ok "$url" "$output"; then
    warn "$(msg '已校验并复用下载文件:' 'Verified and reusing downloaded file:') $output"
    return 0
  fi
  if [[ -f "$output" ]]; then
    warn "$(msg '缓存文件无效、来源不同或版本已变化，将重新下载。' 'Cached file is invalid, from a different source, or outdated; downloading again.')"
  fi

  step "$(msg '下载' 'Download') $(printf '%q' "$url") -> $(printf '%q' "$output")"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if ! mkdir -p -- "$(dirname "$output")"; then
    err "$(msg '无法创建下载缓存目录。' 'Could not create the download cache directory.')"
    exit 1
  fi
  part="$output.part.$$"
  rm -f -- "$part"
  if ! download_with_retries "$url" "$part"; then
    rm -f -- "$part"
    err "$(msg '下载失败，原文件未被覆盖。' 'Download failed; the original file was not replaced.')"
    exit 1
  fi
  if ! archive_is_safe "$part"; then
    rm -f -- "$part"
    err "$(msg '下载的压缩包损坏或包含不安全路径。' 'Downloaded archive is corrupt or contains unsafe paths.')"
    exit 1
  fi

  actual="$(sha256sum "$part" | awk '{print $1}')"
  expected="$(expected_archive_sha256 "$url" || true)"
  hash_source="${DOWNLOAD_TRUST_SOURCE:-installer pinned SHA-256}"
  echo "$(msg '矿工下载来源' 'Miner download source'): $url"
  echo "$(msg '发布方参考' 'Publisher reference'): $(publisher_reference "$url")"
  echo "$(msg '下载文件 SHA-256' 'Downloaded file SHA-256'): $actual"
  if [[ -z "$expected" ]]; then
    echo "$(msg '上游 SHA-256' 'Upstream SHA-256'): $(msg '未提供' 'not available')"
    echo "$(msg '对比结果' 'Comparison'): $(msg '无法与上游摘要对比，仅记录本地值' 'no upstream digest to compare; local value only')"
    warn "$(msg '上游未提供 SHA-256；下载地址已通过矿池官方 HTTPS 白名单。确认后可继续安装，并记录本地摘要供后续完整性检查。' 'No upstream SHA-256 was published. The URL passed the official pool HTTPS allowlist. You can continue after confirmation, and a local digest will be recorded for later integrity checks.')"
  else
    echo "$(msg '预期 SHA-256' 'Expected SHA-256'): $expected"
    echo "$(msg '摘要来源' 'Digest source'): $hash_source"
  fi
  if [[ -n "$expected" && "$actual" != "$expected" ]]; then
    echo "$(msg '对比结果' 'Comparison'): $(msg '不一致，拒绝安装' 'MISMATCH; installation refused')"
    rm -f -- "$part"
    err "$(msg '下载文件 SHA-256 与上游或脚本提供的可信值不一致。' 'Downloaded file SHA-256 does not match the trusted upstream or installer value.')"
    exit 1
  fi
  if [[ -n "$expected" ]]; then
    echo "$(msg '对比结果' 'Comparison'): $(msg '一致' 'MATCH')"
  fi
  if ! ask_yes_no "$(msg '确认使用上述来源和校验结果，继续安装此矿工?' 'Use this source and verification result to install the miner?')" 0; then
    rm -f -- "$part"
    warn "$(msg '已取消安装，下载文件未加入缓存。' 'Installation cancelled; the download was not added to the cache.')"
    exit 1
  fi

  if ! mv -f -- "$part" "$output"; then
    rm -f -- "$part"
    err "$(msg '无法原子替换下载缓存。' 'Could not atomically replace the download cache.')"
    exit 1
  fi
  sidecar_tmp="$output.sha256.tmp.$$"
  url_tmp="$output.url.tmp.$$"
  if ! printf '%s  %s\n' "$actual" "$(basename "$output")" > "$sidecar_tmp" \
    || ! printf '%s\n' "$url" > "$url_tmp" \
    || ! chmod 600 "$sidecar_tmp" "$url_tmp" \
    || ! mv -f -- "$sidecar_tmp" "$output.sha256" \
    || ! mv -f -- "$url_tmp" "$output.url"; then
    rm -f -- "$sidecar_tmp" "$url_tmp"
    err "$(msg '写入下载校验记录失败。' 'Failed to write download verification metadata.')"
    exit 1
  fi
}

migrate_legacy_install_manifest() {
  local url="$1"
  local binary="$2"
  local manifest="$3"
  local installed_url archive_name archive recorded_archive actual_archive
  local tmp installed_at extracted_sha binary_sha
  local -a found=()

  [[ "$DRY_RUN" -eq 0 && -f "$manifest" && ! -L "$manifest" ]] || return 1
  installed_url="$(state_value "$manifest" url)"
  recorded_archive="$(state_value "$manifest" archive_sha256)"
  [[ -n "$installed_url" && "$installed_url" == "$url" \
    && "$recorded_archive" =~ ^[0-9a-f]{64}$ ]] || return 1
  archive_name="$(basename "${installed_url%%\?*}")"
  [[ "$archive_name" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]] || return 1
  archive="$DOWNLOADS_DIR/$archive_name"
  [[ -f "$archive" && ! -L "$archive" ]] || return 1
  archive_integrity_ok "$installed_url" "$archive" || return 1
  actual_archive="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual_archive" == "$recorded_archive" ]] || return 1

  tmp="$(mktemp -d "$DOWNLOADS_DIR/migrate.XXXXXX")" || return 1
  if ! tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$tmp"; then
    rm -rf -- "$tmp"
    return 1
  fi
  mapfile -t found < <(find "$tmp" -type f -name "$(basename "$binary")" -print)
  if [[ "${#found[@]}" -ne 1 ]]; then
    rm -rf -- "$tmp"
    return 1
  fi
  extracted_sha="$(sha256sum "${found[0]}" | awk '{print $1}')"
  binary_sha="$(sha256sum "$binary" | awk '{print $1}')"
  rm -rf -- "$tmp"
  [[ "$extracted_sha" == "$binary_sha" ]] || return 1

  installed_at="$(state_value "$manifest" installed_at)"
  [[ -n "$installed_at" ]] || installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_file "$manifest" "url=$installed_url
binary=$(basename "$binary")
archive_sha256=$recorded_archive
binary_sha256=$binary_sha
installed_at=$installed_at"
  warn "$(msg '已通过可信缓存补全旧安装清单的 binary SHA-256。' 'Safely migrated the legacy manifest using the trusted cached archive and matching binary SHA-256.')"
}

should_install_binary() {
  local url="$1"
  local binary="$2"
  local manifest="$3"
  local installed_url="" installed_archive="" recorded_binary=""
  local recorded_binary_sha="" actual_binary_sha="" remote_sha=""

  [[ "$FORCE_DOWNLOAD" -eq 1 || ! -x "$binary" ]] && return 0
  if [[ -L "$manifest" || ! -f "$manifest" ]]; then
    warn "$(msg '本地 miner 缺少可信安装清单，无法验证二进制。' 'The local miner has no trusted install manifest, so its binary cannot be verified.')"
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    if [[ "$AUTO_YES" -eq 1 ]]; then
      err "$(msg '--yes 拒绝复用未验证二进制；请添加 --force-download。' '--yes refuses an unverified binary; add --force-download.')"
      return 2
    fi
    if ask_yes_no "$(msg '是否下载可信版本并替换?' 'Download and replace it with a trusted version?')" 1; then
      return 0
    fi
    return 2
  fi

  installed_url="$(state_value "$manifest" url)"
  installed_archive="$(state_value "$manifest" archive_sha256)"
  recorded_binary="$(state_value "$manifest" binary)"
  recorded_binary_sha="$(state_value "$manifest" binary_sha256)"
  # PPLNS and Solo are different clients, not interchangeable versions.
  # The asset name also identifies the mode in pre-existing manifests.
  if [[ "$(basename "$binary")" == "qubjetski-Client" \
    && "${installed_url##*/}" != "${url##*/}" ]]; then
    warn "$(msg 'JetSki 模式包已变化，必须安装所选模式的客户端。' 'The JetSki mode asset changed; installing the client for the selected mode.')"
    return 0
  fi
  if [[ "$recorded_binary" == "$(basename "$binary")" \
    && "$installed_archive" =~ ^[0-9a-f]{64}$ \
    && ! "$recorded_binary_sha" =~ ^[0-9a-f]{64}$ ]] \
    && migrate_legacy_install_manifest "$url" "$binary" "$manifest"; then
    installed_url="$(state_value "$manifest" url)"
    installed_archive="$(state_value "$manifest" archive_sha256)"
    recorded_binary="$(state_value "$manifest" binary)"
    recorded_binary_sha="$(state_value "$manifest" binary_sha256)"
  fi
  if [[ "$recorded_binary" != "$(basename "$binary")" \
    || ! "$installed_archive" =~ ^[0-9a-f]{64}$ \
    || ! "$recorded_binary_sha" =~ ^[0-9a-f]{64}$ ]]; then
    warn "$(msg '本地 miner 安装清单过旧或不完整，无法验证二进制。' 'The local miner manifest is old or incomplete, so its binary cannot be verified.')"
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    if [[ "$AUTO_YES" -eq 1 ]]; then
      err "$(msg '--yes 拒绝复用未验证二进制；请添加 --force-download 完成一次可信迁移。' '--yes refuses an unverified binary; add --force-download for a one-time trusted migration.')"
      return 2
    fi
    if ask_yes_no "$(msg '是否重新下载并建立完整安装清单?' 'Redownload and create a complete install manifest?')" 1; then
      return 0
    fi
    return 2
  fi

  actual_binary_sha="$(sha256sum "$binary" 2>/dev/null | awk '{print $1}')"
  if [[ "$actual_binary_sha" != "$recorded_binary_sha" ]]; then
    err "$(msg '本地 miner SHA-256 与安装清单不一致，拒绝运行可能被替换或损坏的文件。' 'The local miner SHA-256 does not match its manifest; refusing a possibly replaced or corrupt binary.')"
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    if [[ "$AUTO_YES" -eq 0 ]] \
      && ask_yes_no "$(msg '是否下载可信版本并修复?' 'Download a trusted version to repair it?')" 1; then
      return 0
    fi
    err "$(msg '请使用 --force-download 修复本地二进制。' 'Use --force-download to repair the local binary.')"
    return 2
  fi

  remote_sha="$(expected_archive_sha256 "$url" || true)"
  if [[ -n "$installed_url" && "$installed_url" == "$url" ]]; then
    if [[ -n "$remote_sha" && "$installed_archive" != "$remote_sha" ]]; then
      warn "$(msg '远端可信 hash 已变化，发现新版本资产。' 'The trusted remote hash changed; a new release asset is available.')"
      if [[ "$AUTO_YES" -eq 1 ]]; then
        warn "$(msg '--yes 保留当前已验证版本；如需更新请加 --force-download。' '--yes keeps the currently verified version; add --force-download to update.')"
        return 1
      fi
      if ask_yes_no "$(msg '是否下载并替换为新的可信版本?' 'Download and replace it with the new trusted version?')" 0; then
        return 0
      fi
      return 1
    fi
    warn "$(msg '本地 miner 二进制与安装清单校验通过，将复用:' 'The local miner binary matches its install manifest; reusing:') $binary"
    return 1
  fi

  warn "$(msg '远端下载地址已变化，但当前本地 miner 的 SHA-256 校验通过。' 'The remote download URL changed, but the current local miner passed SHA-256 verification.')"
  if [[ "$AUTO_YES" -eq 1 ]]; then
    warn "$(msg '--yes 默认保留当前已验证版本；如需替换请加 --force-download。' '--yes keeps the currently verified version by default; add --force-download to replace it.')"
    return 1
  fi
  if ask_yes_no "$(msg '是否下载并替换为当前远端版本?' 'Download and replace it with the current remote version?')" 0; then
    return 0
  fi
  return 1
}

write_install_manifest() {
  local install_dir="$1"
  local url="$2"
  local binary="$3"
  local archive="$4"
  local digest binary_digest
  digest="$(sha256sum "$archive" 2>/dev/null | awk '{print $1}')"
  binary_digest="$(sha256sum "$install_dir/$binary" 2>/dev/null | awk '{print $1}')"
  if [[ ! "$digest" =~ ^[0-9a-f]{64}$ || ! "$binary_digest" =~ ^[0-9a-f]{64}$ ]]; then
    err "$(msg '无法生成完整安装清单，拒绝继续。' 'Could not create a complete install manifest; refusing to continue.')"
    exit 1
  fi
  write_file "$install_dir/.miner-install.version" "url=$url
binary=$binary
archive_sha256=$digest
binary_sha256=$binary_digest
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

install_binary_from_archive() {
  local url="$1"
  local archive_name="$2"
  local install_dir="$3"
  local binary_name="$4"
  local archive="$DOWNLOADS_DIR/$archive_name"
  local manifest="$install_dir/.miner-install.version"
  local install_decision

  if [[ -L "$install_dir/$binary_name" ]]; then
    err "$(msg '拒绝复用或覆盖符号链接形式的 miner:' 'Refusing symlinked miner binary:') $install_dir/$binary_name"
    exit 1
  fi
  should_install_binary "$url" "$install_dir/$binary_name" "$manifest"
  install_decision=$?
  case "$install_decision" in
    0) ;;
    1) return 0 ;;
    *) exit 1 ;;
  esac

  download_archive "$url" "$archive"
  ensure_dir "$install_dir"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    step "$(msg '解压并复制' 'Extract and copy') '$binary_name': '$archive' -> '$install_dir'"
    return 0
  fi

  local tmp binary_tmp extracted_binary_sha
  local -a found=()
  if ! tmp="$(mktemp -d "$DOWNLOADS_DIR/extract.XXXXXX")"; then
    err "$(msg '无法创建解压临时目录。' 'Could not create a temporary extraction directory.')"
    exit 1
  fi
  if ! tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$tmp"; then
    rm -rf "$tmp"
    err "$(msg '解压失败:' 'Archive extraction failed:') $archive"
    exit 1
  fi
  mapfile -t found < <(find "$tmp" -type f -name "$binary_name" -print)
  if [[ "${#found[@]}" -ne 1 ]]; then
    rm -rf "$tmp"
    err "$(msg '压缩包中的目标二进制数量不是 1:' 'Archive does not contain exactly one target binary:') $binary_name"
    exit 1
  fi
  if [[ "$binary_name" == "qlab-miner" && -n "$MINERLAB_BINARY_SHA256" ]]; then
    extracted_binary_sha="$(sha256sum "${found[0]}" 2>/dev/null | awk '{print $1}')"
    if [[ "$extracted_binary_sha" != "$MINERLAB_BINARY_SHA256" ]]; then
      rm -rf "$tmp"
      err "$(msg '归档中的 qlab-miner SHA-256 与 Minerlab 官方值不一致。' 'The qlab-miner SHA-256 in the archive does not match the official Minerlab value.')"
      exit 1
    fi
  fi
  binary_tmp="$install_dir/.${binary_name}.tmp.$$"
  if ! cp -- "${found[0]}" "$binary_tmp" \
    || ! chmod 755 "$binary_tmp" \
    || ! mv -f -- "$binary_tmp" "$install_dir/$binary_name"; then
    rm -f -- "$binary_tmp"
    rm -rf "$tmp"
    err "$(msg '安装 miner 二进制失败。' 'Failed to install the miner binary.')"
    exit 1
  fi
  rm -rf "$tmp"
  write_install_manifest "$install_dir" "$url" "$binary_name" "$archive"
}

install_minerlab_assets() {
  local minerlab_url="${DOWNLOAD_URLS[0]}"
  local archive_name
  archive_name="$(basename "${minerlab_url%%\?*}")"

  install_binary_from_archive "$minerlab_url" "$archive_name" "$INSTALL_DIR" "qlab-miner"
  if [[ "$DRY_RUN" -eq 0 && -f "$(legacy_minerlab_binary_path)" \
    && ! -L "$(legacy_minerlab_binary_path)" ]]; then
    rm -f -- "$(legacy_minerlab_binary_path)"
  fi
}

prepare_jetski_runtime() {
  local cpu_value="false"
  local gpu_value="false"
  local stage stage_binary generated normalized config_tmp
  local -a stage_setup_args
  [[ "$FLAG_CPU" == "1" ]] && cpu_value="true"
  [[ "$FLAG_GPU" == "1" ]] && gpu_value="true"

  step "$(msg '在临时目录生成并验证 JetSki 配置:' 'Generate and validate JetSki config in a staging directory:') $CONFIG_PATH"
  step "$SETUP_CMD"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return 0
  fi

  if [[ -L "$CONFIG_PATH" ]]; then
    err "$(msg '拒绝覆盖符号链接:' 'Refusing to overwrite symlink:') $CONFIG_PATH"
    return 1
  fi
  if [[ -L "$CONFIG_PATH.previous" ]]; then
    err "$(msg '拒绝覆盖备份符号链接:' 'Refusing to overwrite backup symlink:') $CONFIG_PATH.previous"
    return 1
  fi
  if ! mkdir -p -- "$INSTALL_DIR"; then
    err "$(msg '无法创建 JetSki 安装目录。' 'Could not create the JetSki install directory.')"
    return 1
  fi
  if ! stage="$(mktemp -d "$INSTALL_DIR/.jetski-stage.XXXXXX")"; then
    err "$(msg '无法创建 JetSki staging 目录。' 'Could not create the JetSki staging directory.')"
    return 1
  fi
  if [[ -L "$MINER_BINARY_PATH" || ! -f "$MINER_BINARY_PATH" || ! -x "$MINER_BINARY_PATH" ]]; then
    rm -rf -- "$stage"
    err "$(msg 'JetSki binary 无效，无法生成配置。' 'The JetSki binary is invalid; configuration cannot be generated.')"
    return 1
  fi

  # JetSki writes beside its executable, not necessarily into the current directory.
  stage_binary="$stage/qubjetski-Client"
  if ! cp -- "$MINER_BINARY_PATH" "$stage_binary" || ! chmod 700 "$stage_binary"; then
    rm -rf -- "$stage"
    err "$(msg '无法把 JetSki binary 复制到 staging。' 'Could not copy the JetSki binary into staging.')"
    return 1
  fi
  stage_setup_args=("$stage_binary" "${SETUP_ARGS[@]:1}")
  if ! (cd "$stage" && "${stage_setup_args[@]}"); then
    rm -rf -- "$stage"
    err "$(msg 'JetSki 配置生成失败。' 'JetSki configuration generation failed.')"
    return 1
  fi
  generated="$stage/appsettings.json"
  if [[ -L "$generated" || ! -f "$generated" ]]; then
    rm -rf -- "$stage"
    err "$(msg 'JetSki 未生成 appsettings.json，已停止启动。' 'JetSki did not generate appsettings.json; startup aborted.')"
    return 1
  fi
  if find "$stage" -type l -print -quit | grep -q .; then
    rm -rf -- "$stage"
    err "$(msg 'JetSki staging 输出包含符号链接，拒绝提交。' 'JetSki staging output contains a symlink; refusing to commit it.')"
    return 1
  fi

  normalized="$stage/appsettings.normalized.json"
  if ! awk -v cpu="$cpu_value" -v gpu="$gpu_value" -v threads="$THREADS" '
    /"cpu"[[:space:]]*:/ { section = "cpu" }
    /"gpu"[[:space:]]*:/ { section = "gpu" }
    section != "" && /"enabled"[[:space:]]*:/ {
      value = (section == "cpu" ? cpu : gpu)
      sub(/"enabled"[[:space:]]*:[[:space:]]*(true|false)/, "\"enabled\": " value)
    }
    section == "cpu" && /"threads"[[:space:]]*:/ {
      sub(/"threads"[[:space:]]*:[[:space:]]*[0-9]+/, "\"threads\": " threads)
    }
    { print }
  ' "$generated" > "$normalized"; then
    rm -rf -- "$stage"
    err "$(msg '无法校正 JetSki CPU/GPU 配置。' 'Could not normalize JetSki CPU/GPU configuration.')"
    return 1
  fi
  if ! chmod 600 "$normalized"; then
    rm -rf -- "$stage"
    err "$(msg '无法设置 JetSki staging 配置权限。' 'Could not set permissions on the staged JetSki config.')"
    return 1
  fi

  if ! awk -v cpu="$cpu_value" -v gpu="$gpu_value" '
    /"cpu"[[:space:]]*:/ { section = "cpu" }
    /"gpu"[[:space:]]*:/ { section = "gpu" }
    section != "" && /"enabled"[[:space:]]*:/ {
      expected = (section == "cpu" ? cpu : gpu)
      if ($0 ~ ("\"enabled\"[[:space:]]*:[[:space:]]*" expected)) found[section] = 1
      section = ""
    }
    END { exit !(found["cpu"] && found["gpu"]) }
  ' "$normalized"; then
    rm -rf -- "$stage"
    err "$(msg 'JetSki 配置中的 CPU/GPU 状态与选择不一致，已停止启动。' 'JetSki CPU/GPU settings do not match the selection; startup aborted.')"
    return 1
  fi

  if [[ -f "$CONFIG_PATH" ]]; then
    if ! cp -- "$CONFIG_PATH" "$CONFIG_PATH.previous" \
      || ! chmod 600 "$CONFIG_PATH.previous"; then
      rm -rf -- "$stage"
      err "$(msg '备份 JetSki 配置失败。' 'Failed to back up the JetSki config.')"
      return 1
    fi
  fi
  config_tmp="$INSTALL_DIR/.jetski-config.tmp.$$"
  if ! cp -- "$normalized" "$config_tmp" \
    || ! chmod 600 "$config_tmp" \
    || ! mv -f -- "$config_tmp" "$CONFIG_PATH"; then
    rm -f -- "$config_tmp"
    rm -rf -- "$stage"
    err "$(msg '无法原子替换 JetSki 配置。' 'Could not atomically replace the JetSki config.')"
    return 1
  fi

  [[ "$FLAG_CPU" == "1" ]] || rm -f -- "$INSTALL_DIR/workerConfig-CPU.lock"
  [[ "$FLAG_GPU" == "1" ]] || rm -f -- "$INSTALL_DIR/workerConfig-GPU.lock"
  rm -rf -- "$stage"
}

write_runtime_state() {
  local ticks tmp
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  ticks="$(process_start_ticks "$STARTED_PID" || true)"
  if ! tmp="$(mktemp "$INSTALL_DIR/.miner-state.tmp.XXXXXX")"; then
    err "$(msg '无法创建 miner 状态临时文件。' 'Could not create the miner state temporary file.')"
    return 1
  fi
  if ! {
    printf 'pool=%s\n' "$POOL"
    printf 'pid=%s\n' "$STARTED_PID"
    printf 'start_ticks=%s\n' "$ticks"
    printf 'binary=%s\n' "$MINER_BINARY_PATH"
    printf 'log=%s\n' "$LOG_PATH"
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$STATE_PATH"; then
    rm -f -- "$tmp"
    err "$(msg '写入 miner 状态失败。' 'Failed to write miner runtime state.')"
    return 1
  fi
}

start_miner() {
  local output_path="$LOG_PATH"
  local attempt

  step "$START_CMD"
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  if [[ -L "$MINER_BINARY_PATH" || ! -f "$MINER_BINARY_PATH" || ! -x "$MINER_BINARY_PATH" ]]; then
    err "$(msg 'miner 必须是项目目录中的普通可执行文件:' 'Miner must be a regular executable in the project directory:') $MINER_BINARY_PATH"
    return 1
  fi
  if [[ -L "$output_path" || -L "$LOG_PATH" ]]; then
    err "$(msg '拒绝写入符号链接形式的日志文件。' 'Refusing to write to a symlinked log file.')"
    return 1
  fi
  if ! mkdir -p -- "$(dirname "$output_path")"; then
    err "$(msg '无法创建日志目录。' 'Could not create the log directory.')"
    return 1
  fi
  START_LOG_PATH="$output_path"
  START_LOG_OFFSET=0
  if [[ -f "$output_path" ]]; then
    START_LOG_OFFSET="$(stat -c '%s' "$output_path" 2>/dev/null || echo 0)"
    [[ "$START_LOG_OFFSET" =~ ^[0-9]+$ ]] || START_LOG_OFFSET=0
  fi
  START_ATTEMPTED=1
  (
    exec 9>&-
    cd "$INSTALL_DIR" || exit 1
    trap - INT TERM
    exec setsid "${START_ARGS[@]}" >> "$output_path" 2>&1
  ) &
  STARTED_PID=$!

  for attempt in {1..20}; do
    if pid_matches_pool "$STARTED_PID" "$POOL"; then
      if ! write_runtime_state; then
        kill -TERM "$STARTED_PID" 2>/dev/null || true
        return 1
      fi
      return 0
    fi
    kill -0 "$STARTED_PID" 2>/dev/null || break
    sleep 0.1
  done
  return 1
}

check_startup_log_health() {
  local content restart_count
  [[ -n "$START_LOG_PATH" && -f "$START_LOG_PATH" ]] || return 0
  content="$(tail -c "+$((START_LOG_OFFSET + 1))" "$START_LOG_PATH" 2>/dev/null \
    | tail -c 131072)"
  [[ -n "$content" ]] || return 0

  if printf '%s\n' "$content" | grep -Eiq \
    'deterministic startup integrity check FAILED|segmentation fault|unhandled exception|(^|[^a-z])(fatal|panic)([^a-z]|$)|authentication failed|unauthorized|access.?token.*(invalid|expired)|permission denied'; then
    return 1
  fi
  restart_count="$(printf '%s\n' "$content" \
    | grep -Eic 'not running or has exited[.] Starting the process' || true)"
  (( restart_count < 2 ))
}

authorize_existing_miners() {
  local running
  running="$(known_miners_running)"
  [[ -z "$running" ]] && return 0

  warn "$(msg '检测到已有 miner 正在运行；本安装器默认只允许一个 miner。' 'A miner is already running; this installer allows only one miner by default.')"
  printf '%s\n' "$running"
  if [[ "$STOP_EXISTING" -eq 1 ]]; then
    return 0
  fi
  if [[ "$AUTO_YES" -eq 1 ]]; then
    err "$(msg '--yes 不会静默启动第二个 miner；请先停止，或显式添加 --stop-existing。' '--yes will not silently start a second miner; stop it first or explicitly add --stop-existing.')"
    return 1
  fi
  if ask_yes_no "$(msg '是否在改写安装文件前停止以上进程?' 'Stop the processes above before changing installation files?')" 0; then
    STOP_EXISTING=1
    return 0
  fi
  err "$(msg '已取消，未启动第二个 miner。' 'Cancelled; a second miner was not started.')"
  return 1
}

stop_existing_if_needed() {
  local pool running failed=0
  running="$(known_miners_running)"
  [[ -z "$running" ]] && return 0

  if [[ "$STOP_EXISTING" -eq 0 ]]; then
    err "$(msg '启动前检测到新的或未授权的 miner 进程，已停止以避免重复运行。' 'A new or unauthorized miner process appeared before startup; stopping to avoid duplicate mining.')"
    printf '%s\n' "$running"
    return 1
  fi

  for pool in qli jetski minerlab; do
    stop_pool_processes "$pool" || failed=1
  done
  if legacy_qlab_active; then
    warn "$(msg '旧 qlab.service 仍在运行；本脚本不会请求 sudo 或自动停止它。' 'Legacy qlab.service is still running; this script will not request sudo or stop it automatically.')"
    failed=1
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    running="$(known_miners_running)"
    if [[ -n "$running" ]]; then
      err "$(msg '仍有已知 miner 在运行，拒绝启动第二个实例。' 'A known miner is still running; refusing to start a second instance.')"
      printf '%s\n' "$running"
      failed=1
    fi
  fi
  [[ "$failed" -eq 0 ]]
}

execute_pool() {
  # Even --no-start changes live files. Stop authorized existing miners before
  # replacing their binaries, manifests, configs, or device locks.
  if ! stop_existing_if_needed; then
    return 1
  fi
  case "$POOL" in
    qli)
      local qli_archive_name
      qli_archive_name="$(basename "${DOWNLOAD_URLS[0]%%\?*}")"
      if [[ ! "$qli_archive_name" =~ ^[A-Za-z0-9._-]+\.tar\.gz$ ]]; then
        err "$(msg 'QLI 下载文件名格式不安全。' 'Unsafe QLI archive filename.')"
        return 1
      fi
      install_binary_from_archive "${DOWNLOAD_URLS[0]}" "$qli_archive_name" "$INSTALL_DIR" "qli-Client"
      write_file "$CONFIG_PATH" "$CONFIG_CONTENT"
      ;;
    jetski)
      install_binary_from_archive "${DOWNLOAD_URLS[0]}" "$JETSKI_ARCHIVE_NAME" "$INSTALL_DIR" "qubjetski-Client"
      if ! prepare_jetski_runtime; then
        return 1
      fi
      ;;
    minerlab)
      install_minerlab_assets
      write_file "$CONFIG_PATH" "$CONFIG_CONTENT"
      ;;
  esac

  if [[ "$NO_START" -eq 1 ]]; then
    warn "$(msg '已跳过启动。' 'Start skipped.')"
    return
  fi

  ensure_dir "$(dirname "$LOG_PATH")"
  if ! stop_existing_if_needed; then
    return 1
  fi
  if ! start_miner; then
    STARTUP_STATUS="failed"
    err "$(msg 'miner 进程未能启动，请查看日志。' 'Miner process failed to start; check the log.')"
    return 1
  fi
}

check_status() {
  [[ "$NO_START" -eq 1 ]] && return 0
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  sleep 3

  if [[ -n "$STARTED_PID" ]] && pid_matches_pool "$STARTED_PID" "$POOL"; then
    if ! check_startup_log_health; then
      STARTUP_STATUS="unhealthy"
      err "$(msg '启动异常: 日志中发现严重错误，已停止 miner。' 'Startup issue: a critical log error was found, so the miner was stopped.')"
      stop_pool_processes "$POOL" || true
      return 1
    fi
    STARTUP_STATUS="running"
    info "$(msg 'miner 已在后台运行。' 'The miner is now running in the background.')"
    return 0
  else
    STARTUP_STATUS="failed"
    warn "$(msg '启动失败: 未检测到 miner 进程，请查看日志。' 'Startup failed: the miner process was not detected; check the log.')"
    clear_pool_state "$POOL"
    return 1
  fi
}

result_card() {
  section "$(msg '结果' 'Result')"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    msg '状态: 仅完成预演，未执行安装或启动' 'Status: dry-run only; nothing was installed or started'
    msg '预演模式未执行任何文件或进程变更；可能只读取了少量上游发布元数据。' 'Dry-run made no file or process changes; it may only have read small upstream release metadata.'
    return 0
  fi
  if [[ "$NO_START" -eq 1 ]]; then
    msg '状态: 已完成安装和配置，按要求未启动' 'Status: installed and configured; not started as requested'
    echo "$(msg '配置' 'Config'): $CONFIG_PATH"
    echo "$(msg '手动启动' 'Manual start'): $START_CMD"
    return 0
  fi
  case "$STARTUP_STATUS" in
    running)
      msg '状态: 运行中' 'Status: running'
      msg '启动检查: 暂未发现严重错误' 'Startup check: no critical errors found'
      msg '下一步: 等待几分钟后查看日志或矿池面板，确认算力和 Share。' 'Next: wait a few minutes, then check the log or pool dashboard for hashrate and shares.'
      ;;
    unhealthy)
      msg '状态: 启动异常，miner 已停止' 'Status: startup issue; miner stopped'
      msg '启动检查: 日志中发现严重错误' 'Startup check: a critical log error was found'
      ;;
    failed) msg '状态: 启动失败' 'Status: startup failed' ;;
    *) ;;
  esac
  echo "$(msg '日志' 'Log'): tail -f '$LOG_PATH'"
  echo "$(msg '停止' 'Stop'): $STOP_CMD"
  echo "$(msg '脚本查看状态' 'Script status'): $(script_entry_hint) --status --lang=${LANG_CHOICE:-en}"
  echo "$(msg '脚本停止' 'Script stop'): $(script_entry_hint) ${POOL:-} --stop --lang=${LANG_CHOICE:-en}"
  msg '提示: 启动后按 Ctrl+C 只会退出脚本或日志查看，不会自动停止后台 miner。' 'Tip: after startup, Ctrl+C exits the script or log viewer; it does not automatically stop the background miner.'
  if [[ "$AUTO_YES" -eq 0 ]]; then
    if ask_yes_no "$(msg '现在查看日志?' 'View log now?')" 0; then
      tail_log "$LOG_PATH"
    fi
  fi
}

main() {
  # Loading the saved preference is read-only and lets early parse errors use
  # the user's language; an explicit --lang still overrides it.
  load_saved_language || true
  parse_args "$@"
  handle_language_change
  ensure_language
  validate_action_arguments
  trap handle_interrupt INT

  environment_check
  handle_action_mode

  if [[ -z "$POOL" ]]; then
    if [[ "$AUTO_YES" -eq 1 ]]; then
      err "$(msg '--yes 模式必须通过参数或 MINER_POOL 指定矿池。' '--yes mode requires a pool argument or MINER_POOL.')"
      exit 1
    fi
    if [[ "$AUTO_YES" -eq 0 ]]; then
      manage_existing_miners
    fi
    select_pool_interactive
  fi

  validate_pool_options
  validate_pool_platform
  prepare_pool
  print_summary

  if ! ask_yes_no "$(msg '确认执行以上操作?' 'Proceed with these actions?')" 0; then
    warn "$(msg '已取消。' 'Cancelled.')"
    exit 0
  fi

  if ! authorize_existing_miners; then
    exit 1
  fi
  if ! validate_mutation_paths; then
    exit 1
  fi
  acquire_install_lock
  if ! execute_pool; then
    result_card
    exit 1
  fi
  if ! check_status; then
    result_card
    exit 1
  fi
  result_card
}

main "$@"
