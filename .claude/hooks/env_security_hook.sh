#!/bin/bash
# PreToolUse hook to block access to .env files and env-exposing commands
# This hook denies:
#   - Read/Write/Edit/Glob operations on .env files
#   - Bash commands that expose environment variables (printenv, env, export, set, etc.)

set -euo pipefail

# Read JSON input from stdin
INPUT=$(cat)

# Extract hook event and tool info
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {}')

# Helper function to output deny decision
deny_access() {
    local reason="$1"
    jq -n --arg reason "$reason" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $reason
        }
    }'
    exit 0
}

# Helper function to check if path targets .env files
is_env_file() {
    local path="$1"
    # Normalize path - remove leading/trailing whitespace
    path=$(echo "$path" | xargs)

    # Block path traversal attempts
    if [[ "$path" == *".."* ]]; then
        return 0  # Treat as suspicious
    fi

    local basename
    basename=$(basename "$path" 2>/dev/null || echo "$path")

    # ALLOW safe patterns first (example/sample/template files)
    case "$basename" in
        .env.example|.env.sample|.env.template|env.example|env.sample|env.template)
            return 1  # Safe - allow access
            ;;
        *.example|*.sample|*.template)
            return 1  # Safe - allow access
            ;;
    esac

    # BLOCK dangerous .env patterns
    case "$basename" in
        .env|.env.local|.env.development|.env.production|.env.test|.env.staging)
            return 0  # Is a sensitive env file
            ;;
        .env.*)
            # Block .env.* except already allowed patterns above
            return 0
            ;;
    esac

    # Check if path contains sensitive .env patterns (for glob patterns)
    # But allow example/sample/template variants
    if [[ "$path" == *".env.example"* ]] || [[ "$path" == *".env.sample"* ]] || [[ "$path" == *".env.template"* ]]; then
        return 1  # Safe
    fi

    if [[ "$path" == *"/.env"* ]] || [[ "$path" == ".env" ]]; then
        return 0  # Contains sensitive .env pattern
    fi

    return 1  # Not an env file
}

# Check for dangerous environment-exposing commands
is_env_command() {
    local cmd="$1"

    # Dangerous commands that expose environment variables
    local -a blocked_commands=(
        "printenv"
        "^env$"
        "^env "
        " env$"
        " env "
        "^export$"
        "export -p"
        "^set$"
        "^set "
        "declare -x"
        "compgen -e"
        "compgen -v"
        'echo \$'
        'printf.*\$'
        'cat /proc/*/environ'
        '/proc/self/environ'
        '/proc/[0-9]*/environ'
        '\$ENV'
        '\$\{.*\}'
        'xargs.*env'
        'sudo.*printenv'
        'sudo.*env'
    )

    for pattern in "${blocked_commands[@]}"; do
        if echo "$cmd" | grep -qE "$pattern"; then
            return 0  # Is a blocked command
        fi
    done

    return 1  # Not a blocked command
}

# Handle different tool types
case "$TOOL_NAME" in
    Read|Write|Edit)
        FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')
        if [[ -n "$FILE_PATH" ]] && is_env_file "$FILE_PATH"; then
            deny_access "Access to .env files is blocked for security. Use .env.example for templates."
        fi
        ;;

    Glob)
        PATTERN=$(echo "$TOOL_INPUT" | jq -r '.pattern // ""')
        if is_env_file "$PATTERN"; then
            deny_access "Glob patterns targeting .env files are blocked for security."
        fi
        ;;

    Grep)
        PATTERN=$(echo "$TOOL_INPUT" | jq -r '.pattern // ""')
        PATH_ARG=$(echo "$TOOL_INPUT" | jq -r '.path // ""')
        GLOB_ARG=$(echo "$TOOL_INPUT" | jq -r '.glob // ""')

        # Check if searching in .env files
        if [[ -n "$PATH_ARG" ]] && is_env_file "$PATH_ARG"; then
            deny_access "Searching in .env files is blocked for security."
        fi
        if [[ -n "$GLOB_ARG" ]] && is_env_file "$GLOB_ARG"; then
            deny_access "Grep glob patterns targeting .env files are blocked for security."
        fi
        ;;

    Bash)
        COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // ""')

        # Check for environment-exposing commands
        if is_env_command "$COMMAND"; then
            deny_access "Commands that expose environment variables (printenv, env, export, set, etc.) are blocked for security."
        fi

        # Check for cat/less/more/head/tail on .env files (but allow .env.example/.env.sample/.env.template)
        if echo "$COMMAND" | grep -qE '(cat|less|more|head|tail|bat|view|vim|nano|code).*\.env' && \
           ! echo "$COMMAND" | grep -qE '\.env\.(example|sample|template)'; then
            deny_access "Reading .env files via shell commands is blocked for security."
        fi

        # Check for source/dot commands on .env (but allow example/sample/template)
        if echo "$COMMAND" | grep -qE '(source|\.)[ ]+.*\.env' && \
           ! echo "$COMMAND" | grep -qE '\.env\.(example|sample|template)'; then
            deny_access "Sourcing .env files is blocked for security."
        fi
        ;;
esac

# If we reach here, allow the operation (no output = allow)
exit 0
