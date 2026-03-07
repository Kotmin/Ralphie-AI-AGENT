#!/usr/bin/env bash
# notify.sh - Ralph notification system
# Sends notifications about Ralph run status via configurable backends
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
BACKEND="${RALPH_NOTIFY_BACKEND:-mock}"
TOPIC="${RALPH_NOTIFY_TOPIC:-ralph}"
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
LOG_FILE="$ROOT_DIR/.ralph/logs/notifications.log"

# Event metadata
EVENT=""
RUN_ID=""
TASK=""
MESSAGE=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: notify.sh [options]

Send notifications about Ralph run status.

Options:
  --event TYPE      Event type: success, error, clarification, stopped, rate_limit
  --run-id ID       Ralph run ID
  --task ID         Current task ID (optional)
  --message MSG     Notification message
  --dry-run         Show what would be sent without sending
  -h, --help        Show this help

Environment Variables:
  RALPH_NOTIFY_BACKEND   Backend to use: mock, ntfy, slack, discord (default: mock)
  RALPH_NOTIFY_TOPIC     Topic/channel for notifications (default: ralph)
  NTFY_URL               ntfy server URL (default: https://ntfy.sh)
  SLACK_WEBHOOK_URL      Slack incoming webhook URL
  DISCORD_WEBHOOK_URL    Discord webhook URL

Examples:
  # Test with mock backend
  RALPH_NOTIFY_BACKEND=mock ./notify.sh --event success --run-id 123 --message "Done!"

  # Send via ntfy
  RALPH_NOTIFY_BACKEND=ntfy RALPH_NOTIFY_TOPIC=myalerts ./notify.sh --event error --message "Failed"

  # Dry run to test configuration
  ./notify.sh --dry-run --event clarification --message "Need input"
EOF
}

log() {
  printf '[notify] %s\n' "$*" >&2
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get emoji for event type
get_emoji() {
  case "$1" in
    success)       echo "✅" ;;
    error)         echo "❌" ;;
    clarification) echo "❓" ;;
    stopped)       echo "⏹️" ;;
    rate_limit)    echo "🚫" ;;
    *)             echo "📢" ;;
  esac
}

# Get priority for event type (ntfy priority levels)
get_priority() {
  case "$1" in
    success)       echo "default" ;;
    error)         echo "high" ;;
    clarification) echo "urgent" ;;
    stopped)       echo "default" ;;
    rate_limit)    echo "high" ;;
    *)             echo "default" ;;
  esac
}

# Build notification title
build_title() {
  local emoji
  emoji="$(get_emoji "$EVENT")"

  case "$EVENT" in
    success)       echo "$emoji Ralph completed successfully" ;;
    error)         echo "$emoji Ralph encountered an error" ;;
    clarification) echo "$emoji Ralph needs your input" ;;
    stopped)       echo "$emoji Ralph stopped" ;;
    rate_limit)    echo "$emoji Ralph hit rate limit" ;;
    *)             echo "$emoji Ralph notification" ;;
  esac
}

# Build notification body
build_body() {
  local body=""

  [[ -n "$RUN_ID" ]] && body+="Run: $RUN_ID\n"
  [[ -n "$TASK" ]] && body+="Task: $TASK\n"
  [[ -n "$MESSAGE" ]] && body+="\n$MESSAGE"

  printf '%b' "$body"
}

# Mock backend - logs to file
send_mock() {
  local title="$1"
  local body="$2"
  local priority="$3"

  mkdir -p "$(dirname "$LOG_FILE")"

  {
    echo "========================================"
    echo "NOTIFICATION @ $(now_iso)"
    echo "Backend: mock"
    echo "Event: $EVENT"
    echo "Priority: $priority"
    echo "Run ID: $RUN_ID"
    echo "Task: $TASK"
    echo "----------------------------------------"
    echo "Title: $title"
    echo "Body:"
    echo "$body"
    echo "========================================"
    echo ""
  } >> "$LOG_FILE"

  log "Mock notification logged to $LOG_FILE"
  return 0
}

# ntfy backend
send_ntfy() {
  local title="$1"
  local body="$2"
  local priority="$3"

  if [[ -z "$TOPIC" ]]; then
    log "ERROR: RALPH_NOTIFY_TOPIC not set"
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log "ERROR: curl not found"
    return 1
  fi

  local tags=""
  case "$EVENT" in
    success)       tags="white_check_mark,ralph" ;;
    error)         tags="x,ralph,warning" ;;
    clarification) tags="question,ralph" ;;
    stopped)       tags="stop_button,ralph" ;;
    rate_limit)    tags="no_entry,ralph" ;;
  esac

  if curl -fsS -X POST \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -H "Tags: $tags" \
    -d "$body" \
    "$NTFY_URL/$TOPIC" >/dev/null 2>&1; then
    log "Notification sent via ntfy to $NTFY_URL/$TOPIC"
    return 0
  else
    log "WARNING: Failed to send ntfy notification"
    return 1
  fi
}

# Slack backend (placeholder)
send_slack() {
  local title="$1"
  local body="$2"
  local priority="$3"

  local webhook="${SLACK_WEBHOOK_URL:-}"
  if [[ -z "$webhook" ]]; then
    log "ERROR: SLACK_WEBHOOK_URL not set"
    return 1
  fi

  local emoji
  emoji="$(get_emoji "$EVENT")"

  local payload
  payload=$(cat <<PAYLOAD
{
  "text": "$emoji *$title*",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "$emoji *$title*\n$body"
      }
    }
  ]
}
PAYLOAD
)

  if curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$webhook" >/dev/null 2>&1; then
    log "Notification sent via Slack"
    return 0
  else
    log "WARNING: Failed to send Slack notification"
    return 1
  fi
}

# Discord backend (placeholder)
send_discord() {
  local title="$1"
  local body="$2"
  local priority="$3"

  local webhook="${DISCORD_WEBHOOK_URL:-}"
  if [[ -z "$webhook" ]]; then
    log "ERROR: DISCORD_WEBHOOK_URL not set"
    return 1
  fi

  local emoji
  emoji="$(get_emoji "$EVENT")"

  local color
  case "$EVENT" in
    success)       color=5763719 ;;  # Green
    error)         color=15548997 ;; # Red
    clarification) color=16776960 ;; # Yellow
    *)             color=5793266 ;;  # Blue
  esac

  local payload
  payload=$(cat <<PAYLOAD
{
  "embeds": [{
    "title": "$emoji $title",
    "description": "$body",
    "color": $color
  }]
}
PAYLOAD
)

  if curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$webhook" >/dev/null 2>&1; then
    log "Notification sent via Discord"
    return 0
  else
    log "WARNING: Failed to send Discord notification"
    return 1
  fi
}

# Main send function
send_notification() {
  local title body priority
  title="$(build_title)"
  body="$(build_body)"
  priority="$(get_priority "$EVENT")"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "=== DRY RUN ==="
    echo "Backend: $BACKEND"
    echo "Topic: $TOPIC"
    echo "Event: $EVENT"
    echo "Priority: $priority"
    echo "Title: $title"
    echo "Body:"
    echo "$body"
    echo "==============="
    return 0
  fi

  case "$BACKEND" in
    mock)    send_mock "$title" "$body" "$priority" ;;
    ntfy)    send_ntfy "$title" "$body" "$priority" ;;
    slack)   send_slack "$title" "$body" "$priority" ;;
    discord) send_discord "$title" "$body" "$priority" ;;
    *)
      log "ERROR: Unknown backend: $BACKEND"
      return 1
      ;;
  esac
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)   EVENT="${2:?}"; shift 2 ;;
    --run-id)  RUN_ID="${2:?}"; shift 2 ;;
    --task)    TASK="${2:?}"; shift 2 ;;
    --message) MESSAGE="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$EVENT" ]]; then
  echo "ERROR: --event is required" >&2
  usage
  exit 1
fi

# Validate event type
case "$EVENT" in
  success|error|clarification|stopped|rate_limit) ;;
  *)
    echo "ERROR: Invalid event type: $EVENT" >&2
    echo "Valid types: success, error, clarification, stopped, rate_limit" >&2
    exit 1
    ;;
esac

# Send the notification
send_notification
