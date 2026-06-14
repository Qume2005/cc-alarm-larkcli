#!/usr/bin/env bash
# cc-alarm-larkcli/notify.sh — thin wrapper around `lark-cli` to send Feishu
# notifications from a subagent's Bash environment. Best-effort, non-blocking.
#
# Usage: notify.sh <type> "<message>" [--dry-run] [--force] [--markdown] [--help|-h]
# See the plan contract at .claude/development-team/planner/cc-alarm-larkcli-june-14th-2026.md
#
# NOTE: `set -u` (NOT `set -e`). The script controls its own exit codes and must
# not abort on lark-cli failure (failure is non-fatal — caller logs and continues).

set -u

readonly PROG="cc-alarm-larkcli"

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
print_usage() {
  cat <<'EOF'
Usage: notify.sh <type> "<message>" [flags]

Send a Feishu (Lark) notification via lark-cli.

Arguments:
  type       One of: ask | done | progress | error
  message    Body text. Quote it on the command line (no word-splitting).

Flags (any order, after the two positionals):
  --markdown   Send message as markdown (lark-cli --markdown). Default: plain --text.
  --dry-run    Print the resolved lark-cli command line to stdout, do not send, exit 0.
               Still validates args + config, still throttles 'progress' (unless --force).
  --force      Bypass throttle (only meaningful for 'progress'; ignored otherwise).
  -h, --help   Print this help and exit 0.

Config: ~/.config/cc-alarm-larkcli/config.sh (override path via CONFIG_PATH env).
        Set exactly ONE of RECIPIENT_USER_ID / RECIPIENT_CHAT_ID.

Exit codes: 0=ok/dry-run/throttled, 2=config missing or ambiguous,
            3=bad arguments, other=lark-cli send failure (passthrough).
EOF
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
type_name=""
message=""
use_markdown=0
dry_run=0
force=0

show_help=0
positional_count=0
bad_flag=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help=1
      shift
      ;;
    --markdown)
      use_markdown=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --force)
      force=1
      shift
      ;;
    --*)
      bad_flag="$1"
      shift
      ;;
    *)
      # Positional
      positional_count=$((positional_count + 1))
      if [[ "$positional_count" -eq 1 ]]; then
        type_name="$1"
      elif [[ "$positional_count" -eq 2 ]]; then
        message="$1"
      else
        # Too many positionals — treat as bad args.
        bad_flag="extra positional: $1"
      fi
      shift
      ;;
  esac
done

if [[ "$show_help" -eq 1 ]]; then
  print_usage
  exit 0
fi

# Unknown flag / extra positional → exit 3.
if [[ -n "$bad_flag" ]]; then
  echo "$PROG: unknown argument: $bad_flag" >&2
  print_usage >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Validate type (must be lowercase ask|done|progress|error).
# ---------------------------------------------------------------------------
if [[ -z "$type_name" ]]; then
  echo "$PROG: type is required (ask|done|progress|error)" >&2
  print_usage >&2
  exit 3
fi

case "$type_name" in
  ask|done|progress|error) : ;;
  *)
    echo "$PROG: unknown type: '$type_name'; expected one of: ask, done, progress, error" >&2
    exit 3
    ;;
esac

# ---------------------------------------------------------------------------
# Validate message: required, unless --markdown (rare empty-body case allowed).
# Per contract §2: empty message allowed ONLY if --markdown also given.
# ---------------------------------------------------------------------------
if [[ -z "$message" && "$use_markdown" -ne 1 ]]; then
  echo "$PROG: message is required" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Load config.
# ---------------------------------------------------------------------------
# CONFIG_PATH override is for testing; default is the documented user path.
config_path="${CONFIG_PATH:-$HOME/.config/cc-alarm-larkcli/config.sh}"

if [[ ! -f "$config_path" ]]; then
  cat >&2 <<EOF
$PROG: recipient not configured.
Create ~/.config/cc-alarm-larkcli/config.sh with exactly one of:
  RECIPIENT_USER_ID="ou_xxx"   # DM a user
  RECIPIENT_CHAT_ID="oc_xxx"   # send to a chat
See config.example.sh for the full template.
EOF
  exit 2
fi

# shellcheck disable=SC1090
source "$config_path"

# set -u-safe reads of config (contract §10b, verbatim pattern).
uid="${RECIPIENT_USER_ID:-}"
cid="${RECIPIENT_CHAT_ID:-}"
as="${AS:-user}"
throttle="${THROTTLE_SECONDS:-300}"

# Validate throttle: must be a non-negative integer, else fall back to 300.
if ! [[ "$throttle" =~ ^[0-9]+$ ]]; then
  echo "$PROG: THROTTLE_SECONDS='$throttle' invalid, using 300" >&2
  throttle=300
fi

# Exactly one recipient required.
if [[ -z "$uid" && -z "$cid" ]]; then
  cat >&2 <<EOF
$PROG: recipient not configured.
Create ~/.config/cc-alarm-larkcli/config.sh with exactly one of:
  RECIPIENT_USER_ID="ou_xxx"   # DM a user
  RECIPIENT_CHAT_ID="oc_xxx"   # send to a chat
See config.example.sh for the full template.
EOF
  exit 2
fi

# Mutually exclusive.
if [[ -n "$uid" && -n "$cid" ]]; then
  echo "$PROG: recipient ambiguous — set exactly ONE of RECIPIENT_USER_ID / RECIPIENT_CHAT_ID, not both." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Build header from type (contract §3).
# ---------------------------------------------------------------------------
case "$type_name" in
  ask)
    emoji="🙋"
    title="需要你确认"
    ;;
  done)
    emoji="✅"
    title="任务完成"
    ;;
  progress)
    emoji="📊"
    title="进度"
    ;;
  error)
    emoji="❌"
    title="出错了"
    ;;
esac

if [[ "$use_markdown" -eq 1 ]]; then
  header="## ${emoji} ${title}"$'\n\n'
else
  header="${emoji} ${title}"$'\n'
fi

body="${header}${message}"

# ---------------------------------------------------------------------------
# Throttle check (progress type only) — contract §5.
# Even --dry-run runs this check (contract §10a point 2).
# cache_dir/state_file/now are computed unconditionally so the post-send
# throttle update (which runs for ANY successful progress send, including
# --force) has bound variables under `set -u`.
# ---------------------------------------------------------------------------
cache_dir="$HOME/.cache/cc-alarm-larkcli"
state_file="$cache_dir/last_progress"
now="$(date +%s)"

if [[ "$type_name" == "progress" ]]; then
  mkdir -p "$cache_dir"
fi

if [[ "$type_name" == "progress" && "$force" -ne 1 ]]; then
  last=0
  if [[ -f "$state_file" ]]; then
    raw_last="$(cat "$state_file" 2>/dev/null || true)"
    if [[ "$raw_last" =~ ^[0-9]+$ ]]; then
      last="$raw_last"
    fi
  fi

  delta=$((now - last))
  if [[ "$delta" -lt "$throttle" ]]; then
    echo "$PROG: progress throttled (last sent ${delta}s ago, min ${throttle}s; use --force to override)" >&2
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Assemble the lark-cli argv via bash array (contract §7 — mandatory).
# Body is ALWAYS one quoted array element; never word-split.
# ---------------------------------------------------------------------------
cmd=(lark-cli im +messages-send --as "$as")

if [[ -n "$uid" ]]; then
  cmd+=(--user-id "$uid")
fi
if [[ -n "$cid" ]]; then
  cmd+=(--chat-id "$cid")
fi

idem_key="cc-alarm-$(date +%s)-${type_name}-${RANDOM}"
cmd+=(--idempotency-key "$idem_key")

if [[ "$use_markdown" -eq 1 ]]; then
  cmd+=(--markdown "$body")
else
  cmd+=(--text "$body")
fi

cmd+=(--format json)

# ---------------------------------------------------------------------------
# Execute or dry-run.
# ---------------------------------------------------------------------------
if [[ "$dry_run" -eq 1 ]]; then
  # Contract §10a: print fully-formed command line for THIS run.
  # Body is single-quoted; internal ' escaped as '\'' (standard shell idiom).
  # Other tokens (as, recipient id, idempotency key) printed raw.
  {
    printf '%s' "lark-cli im +messages-send"
    printf ' %s' "--as" "$as"
    if [[ -n "$uid" ]]; then
      printf ' %s' "--user-id" "$uid"
    fi
    if [[ -n "$cid" ]]; then
      printf ' %s' "--chat-id" "$cid"
    fi
    printf ' %s' "--idempotency-key" "$idem_key"
    if [[ "$use_markdown" -eq 1 ]]; then
      text_flag="--markdown"
    else
      text_flag="--text"
    fi
    # Single-quote the body, escaping internal single quotes.
    # This prints the body including any embedded newlines as-is, wrapped in '...'.
    printf ' %s ' "$text_flag"
    printf "'"
    printf '%s' "$body" | sed "s/'/'\\\\''/g"
    printf "'"
    printf ' %s\n' "--format json"
  }
  exit 0
fi

# ---------------------------------------------------------------------------
# Real send.
# ---------------------------------------------------------------------------
# Capture combined stdout+stderr for the failure message.
send_out="$("${cmd[@]}" 2>&1)"
send_rc=$?

if [[ "$send_rc" -ne 0 ]]; then
  first_line="$(printf '%s' "$send_out" | head -n 1)"
  if [[ "$send_rc" -lt 1 || "$send_rc" -gt 255 ]]; then
    send_rc=1
  fi
  echo "$PROG: send failed (type=$type_name, lark-cli exit $send_rc); $first_line" >&2
  exit "$send_rc"
fi

# On successful progress send, update throttle state (contract §5 point 5).
if [[ "$type_name" == "progress" ]]; then
  echo "$now" > "$state_file"
fi

exit 0
