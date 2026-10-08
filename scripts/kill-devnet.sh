#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTS=(8545 5173 8790 8791)
PATTERNS=(
  "pnpm dev:fork"
  "DEVNET_FORK=1 pnpm --filter @optara/frontend devnet"
  "pnpm --filter @optara/frontend devnet"
  "tsx scripts/devnet.ts"
  "forge script script/local/LocalStack.s.sol"
  "anvil --port 8545"
  "pnpm --filter @optara/publisher start"
  "pnpm --filter @optara/keepers start"
  "vite"
)

FORCE=0
for arg in "$@"; do
  if [[ "$arg" == "--force" || "$arg" == "-f" ]]; then
    FORCE=1
  fi
done

collect_pids() {
  local pids=()
  local pattern pid

  for pattern in "${PATTERNS[@]}"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && pids+=("$pid")
    done < <(pgrep -f "$pattern" 2>/dev/null || true)
  done

  for port in "${PORTS[@]}"; do
    if command -v lsof >/dev/null 2>&1; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
      done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
    fi
  done

  printf "%s\n" "${pids[@]}" \
    | awk -v self="$$" -v parent="$PPID" 'NF && $1 != self && $1 != parent && !seen[$1]++'
}

PIDS=()
while IFS= read -r pid; do
  [[ -n "$pid" ]] && PIDS+=("$pid")
done < <(collect_pids)

if [[ "${#PIDS[@]}" -eq 0 ]]; then
  echo "No Optara devnet processes found."
  exit 0
fi

echo "Killing Optara devnet processes from $ROOT:"
printf "  %s\n" "${PIDS[@]}"

kill "${PIDS[@]}" 2>/dev/null || true
sleep 1

STILL_RUNNING=()
for pid in "${PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    STILL_RUNNING+=("$pid")
  fi
done

if [[ "${#STILL_RUNNING[@]}" -gt 0 && "$FORCE" -eq 1 ]]; then
  echo "Force killing remaining processes:"
  printf "  %s\n" "${STILL_RUNNING[@]}"
  kill -9 "${STILL_RUNNING[@]}" 2>/dev/null || true
elif [[ "${#STILL_RUNNING[@]}" -gt 0 ]]; then
  echo "Some processes are still running. Re-run with --force if needed:"
  printf "  %s\n" "${STILL_RUNNING[@]}"
  exit 1
fi

echo "Done."
