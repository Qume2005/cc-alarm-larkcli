#!/usr/bin/env bash
# cc-alarm-larkcli/scripts/hook-notify.sh — Claude Code hook entry point.
#
# Wires three lifecycle events (Stop, SubagentStop, Notification) to the
# notify.sh send layer. Pure orchestration: parse hook JSON from stdin,
# map event -> type, extract body (from .message or transcript JSONL),
# throttle per type, then background-dispatch notify.sh and exit 0.
#
# HOOK CONTRACT (verified against official docs):
#   - Always exit 0. Never write to stdout (exit 2 would block the agent
#     and re-trigger Stop, causing recursion).
#   - Consume stdin (the hook JSON) unconditionally.
#   - stop_hook_active == true -> anti-recursion: bail immediately.
#
# Usage: invoked by Claude Code hooks.json; never called directly by users.
# Debug: HOOK_DEBUG=1 -> foreground dry-run of notify.sh, no backgrounding.

set -u

readonly PROG="cc-alarm-larkcli/hook-notify"

# ---------------------------------------------------------------------------
# Step 1: consume stdin JSON (mandatory even if we bail later).
# ---------------------------------------------------------------------------
INPUT="$(cat)"

# ---------------------------------------------------------------------------
# Step 2: parse with jq; graceful degrade if jq absent or JSON invalid.
#   has_jq=1 -> use jq; has_jq=0 -> type-infer via string match.
# ---------------------------------------------------------------------------
has_jq=1
if ! command -v jq >/dev/null 2>&1; then
  has_jq=0
fi

if [ "$has_jq" -eq 1 ]; then
  event="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)"
  stop_active="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
  transcript_path="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)"
  notif_msg="$(printf '%s' "$INPUT" | jq -r '.message // empty' 2>/dev/null)"
  # If jq errored on bad JSON, event will be empty -> falls to unknown-event branch.
else
  # Degrade: type-infer via substring match. Best-effort, never crash.
  if printf '%s' "$INPUT" | grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"Notification"'; then
    event="Notification"
  elif printf '%s' "$INPUT" | grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"Stop"'; then
    event="Stop"
  elif printf '%s' "$INPUT" | grep -q '"hook_event_name"[[:space:]]*:[[:space:]]*"SubagentStop"'; then
    event="SubagentStop"
  else
    event=""
  fi
  if printf '%s' "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    stop_active="true"
  else
    stop_active="false"
  fi
  # Extract transcript_path and message via sed (fragile, fallback only).
  transcript_path="$(printf '%s' "$INPUT" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  notif_msg="$(printf '%s' "$INPUT" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

# ---------------------------------------------------------------------------
# Step 3: anti-recursion guard. stop_hook_active == true -> exit 0 silently.
# ---------------------------------------------------------------------------
if [ "$stop_active" = "true" ]; then
  exit 0
fi

# Suppress SubagentStop entirely: the main agent's Stop carries the turn
# summary, so a separate ping per subagent finish is just noise. No send.
if [ "$event" = "SubagentStop" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 4: event -> type mapping + body resolution.
# ---------------------------------------------------------------------------
type_name=""
body=""

case "$event" in
  Notification)
    type_name="ask"
    if [ -n "$notif_msg" ]; then
      body="$notif_msg"
    else
      body="Claude 通知"
    fi

    # Suppress idle "waiting for your input" notifications — these are false
    # alarms in agent-driven flows. Case-insensitive substring match.
    if [ -n "$notif_msg" ] \
       && printf '%s' "$notif_msg" | grep -qi 'waiting for your input'; then
      exit 0
    fi

    # Enrich non-idle notifications (e.g. permission prompts) with specifics
    # from the MOST RECENT tool_use block in the transcript. Best-effort:
    # any failure (no transcript, no tool_use, jq error) falls back to the
    # original body silently — never crash, never drop the notification.
    if [ -n "$notif_msg" ] && [ "$has_jq" -eq 1 ] \
       && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
      tool_name="$(jq -rs '
        [ .[] | select(.type == "assistant")
               | (.message.content // [])[]
               | select(.type == "tool_use") ] | last | .name // empty
      ' "$transcript_path" 2>/dev/null)"

      if [ -n "$tool_name" ]; then
        case "$tool_name" in
          Bash)
            tool_detail="$(jq -rs '
              [ .[] | select(.type == "assistant")
                     | (.message.content // [])[]
                     | select(.type == "tool_use") ] | last
              | .input.command // empty
            ' "$transcript_path" 2>/dev/null)"
            tool_detail="${tool_detail:0:150}"
            ;;
          Edit|Write|Read|NotebookEdit|MultiEdit)
            tool_detail="$(jq -rs '
              [ .[] | select(.type == "assistant")
                     | (.message.content // [])[]
                     | select(.type == "tool_use") ] | last
              | .input.file_path // empty
            ' "$transcript_path" 2>/dev/null)"
            ;;
          *)
            # Anything else: truncated JSON of the whole .input object.
            tool_detail="$(jq -rs '
              [ .[] | select(.type == "assistant")
                     | (.message.content // [])[]
                     | select(.type == "tool_use") ] | last
              | .input | tostring
            ' "$transcript_path" 2>/dev/null)"
            tool_detail="${tool_detail:0:150}"
            ;;
        esac

        if [ -n "$tool_detail" ]; then
          # Compose: original message + tool name + key detail.
          body="$(printf '%s\n\n工具：%s\n%s' "$notif_msg" "$tool_name" "$tool_detail")"
        else
          body="$(printf '%s\n\n工具：%s' "$notif_msg" "$tool_name")"
        fi
      fi
    fi
    ;;
  Stop|SubagentStop)
    type_name="done"
    fallback="主 agent 一轮结束"
    [ "$event" = "SubagentStop" ] && fallback="子 agent 完成"
    body=""
    # Try to extract the last assistant text block from transcript JSONL.
    if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
      if [ "$has_jq" -eq 1 ]; then
        # Slurp all records, collect assistant text blocks in order, take last.
        # This is robust against multiline text blocks (head -1 would truncate).
        extracted="$(jq -s -r '
          [.[] | select(.type == "assistant")
                 | (.message.content // [])[]
                 | select(.type == "text") | .text] | last // empty
        ' "$transcript_path" 2>/dev/null)"
      else
        # Degrade: grab the last "text" field from any assistant line via grep+sed.
        # Very rough; any failure -> empty -> fallback below.
        extracted="$(grep '"type":"assistant"' "$transcript_path" 2>/dev/null \
          | sed -n 's/.*"type":"text","text":"\([^"]*\)".*/\1/p' | tail -1)"
      fi
      if [ -n "$extracted" ]; then
        # Truncate to 200 chars, then collapse whitespace.
        truncated="${extracted:0:200}"
        body="$(printf '%s' "$truncated" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')"
      fi
    fi
    if [ -z "$body" ]; then
      body="$fallback"
    fi
    ;;
  *)
    # Unknown event -> no-op, exit 0.
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Step 5: per-type throttle.
#   State: ~/.cache/cc-alarm-larkcli/hook_last_<type> (epoch seconds).
#   Window: done=${HOOK_THROTTLE_DONE:-120}, ask=${HOOK_THROTTLE_ASK:-60}.
#   Source config vars first (notify.sh's config may set overrides).
# ---------------------------------------------------------------------------
cache_dir="$HOME/.cache/cc-alarm-larkcli"
state_file="$cache_dir/hook_last_${type_name}"

# If a user config exists and sets HOOK_THROTTLE_* / THROTTLE_SECONDS, honor it.
config_path="${CONFIG_PATH:-$HOME/.config/cc-alarm-larkcli/config.sh}"
throttle_done="${HOOK_THROTTLE_DONE:-120}"
throttle_ask="${HOOK_THROTTLE_ASK:-60}"
if [ -f "$config_path" ]; then
  # shellcheck disable=SC1090
  source "$config_path" 2>/dev/null || true
  throttle_done="${HOOK_THROTTLE_DONE:-$throttle_done}"
  throttle_ask="${HOOK_THROTTLE_ASK:-$throttle_ask}"
fi

if [ "$type_name" = "done" ]; then
  window="$throttle_done"
elif [ "$type_name" = "ask" ]; then
  window="$throttle_ask"
else
  window=0
fi

now="$(date +%s)"
mkdir -p "$cache_dir" 2>/dev/null || true

if [ "$window" -gt 0 ]; then
  last=0
  if [ -f "$state_file" ]; then
    raw_last="$(cat "$state_file" 2>/dev/null || true)"
    if [[ "${raw_last:-0}" =~ ^[0-9]+$ ]]; then
      last="$raw_last"
    fi
  fi
  delta=$((now - last))
  if [ "$delta" -lt "$window" ]; then
    echo "$PROG: 节流跳过 (type=$type_name, ${delta}s since last, window=${window}s)" >&2
    exit 0
  fi
fi

# Throttle passed -> stamp now.
echo "$now" > "$state_file" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 6: locate notify.sh (the pure send layer; do not modify it).
#   Prefer CLAUDE_PLUGIN_ROOT, else derive from this script's location.
# ---------------------------------------------------------------------------
NOTIFY=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh" ]; then
  NOTIFY="${CLAUDE_PLUGIN_ROOT}/scripts/notify.sh"
else
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  candidate="$script_dir/../scripts/notify.sh"
  if [ -f "$candidate" ]; then
    NOTIFY="$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")"
  elif [ -f "$script_dir/notify.sh" ]; then
    # In case hook-notify.sh and notify.sh sit in the same scripts dir.
    NOTIFY="$script_dir/notify.sh"
  fi
fi

if [ -z "$NOTIFY" ] || [ ! -f "$NOTIFY" ]; then
  echo "$PROG: notify.sh not found (looked in CLAUDE_PLUGIN_ROOT and script dir)" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 7: dispatch.
#   HOOK_DEBUG=1 -> foreground --dry-run to stderr for testing.
#   Otherwise     -> backgrounded, fire-and-forget, exit 0 immediately.
# ---------------------------------------------------------------------------
if [ "${HOOK_DEBUG:-0}" = "1" ]; then
  {
    echo "$PROG: [dry-run] would run:" >&2
    echo "  $NOTIFY $type_name <body> --dry-run" >&2
    echo "  type=$type_name" >&2
    echo "  body=$body" >&2
  } >&2
  "$NOTIFY" "$type_name" "$body" --dry-run >&2 2>&1 || true
  exit 0
fi

# Background send; detach so the hook returns immediately.
( "$NOTIFY" "$type_name" "$body" ) >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 8: unconditional success exit. Any earlier unexpected path also lands
# here via the final exit 0 below — the script NEVER exits non-zero.
# ---------------------------------------------------------------------------
exit 0
