#!/bin/sh
# Startup checks for voxtral-daemon --check: backend selection and failure reasons.
# Each case runs a copy of the daemon in a fresh directory with HOME pointing there,
# so the repo's voxtral-model and the caller's config and key never leak in.

DAEMON="$(pwd)/voxtral-daemon"
fail=0
cases=0

# run_case <name> <expected status> <must contain> <must not contain> <setup> <env> [daemon args...]
# setup: none | cfg_only | key600 | key644 ; env: nokey | key
run_case() {
  name=$1 want=$2 has=$3 hasnt=$4 setup=$5 envmode=$6
  shift 6
  cases=$((cases + 1))
  T=$(mktemp -d)
  cp "$DAEMON" "$T/voxtral-daemon"
  case $setup in
  none) ;;
  cfg_only | key600 | key644)
    mkdir -p "$T/.config/voxtral"
    ;;
  esac
  case $setup in
  cfg_only | key600 | key644) printf 'backend = openai\n' >"$T/.config/voxtral/config" ;;
  esac
  case $setup in
  key600)
    printf 'sk-filekey\n' >"$T/.config/voxtral/openai_key"
    chmod 600 "$T/.config/voxtral/openai_key"
    ;;
  key644)
    printf 'sk-filekey\n' >"$T/.config/voxtral/openai_key"
    chmod 644 "$T/.config/voxtral/openai_key"
    ;;
  esac
  if [ "$name" = "bad delay" ]; then
    mkdir -p "$T/.config/voxtral"
    printf 'delay = fast\n' >"$T/.config/voxtral/config"
  fi
  # "$@" may name $T as the model directory
  set -- $(printf '%s ' "$@" | sed "s|@T@|$T|g")
  if [ "$envmode" = key ]; then
    out=$(cd "$T" && HOME="$T" OPENAI_API_KEY=sk-test ./voxtral-daemon --check "$@" 2>&1)
  else
    out=$(cd "$T" && env -u OPENAI_API_KEY HOME="$T" ./voxtral-daemon --check "$@" 2>&1)
  fi
  status=$?
  rm -rf "$T"
  ok=1
  [ "$status" -eq "$want" ] || ok=0
  [ -z "$has" ] || printf '%s' "$out" | grep -q -- "$has" || ok=0
  [ -z "$hasnt" ] || ! printf '%s' "$out" | grep -q -- "$hasnt" || ok=0
  if [ $ok -eq 0 ]; then
    echo "FAIL: $name (status $status, want $want; output: $out)"
    fail=1
  fi
}

run_case "bad delay" 1 "配置无效：delay 的值无效" "" none nokey
run_case "no key" 1 "找不到 OpenAI key" "" cfg_only nokey
run_case "key mode 644" 1 "600" "" key644 nokey
run_case "no model" 1 "voxtral-model" "" none nokey
run_case "key file" 0 "backend: openai" "sk-" key600 nokey
run_case "key env" 0 "backend: openai" "sk-test" cfg_only key
run_case "env key keeps local" 0 "backend: local" "" none key -d @T@

if [ $fail -ne 0 ]; then
  exit 1
fi
echo "test_daemon_startup: all passed"
