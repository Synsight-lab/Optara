#!/usr/bin/env bash
# Top up the Optara testnet operator wallets with testnet MON from a funded wallet.
#
#   scripts/fund-testnet.sh             show the plan, ask, then send
#   scripts/fund-testnet.sh --dry-run   show the plan only
#   scripts/fund-testnet.sh --yes       send without asking
#
# Reads (never prints) the keys from ENV_FILE (default indexer/.env, git-ignored):
#   ACCOUNT_WITH_TEST_FUNDS   private key of the wallet that pays
#   ADDRESS_WITH_TEST_FUNDS   its address (checked against the key)
#   ADMIN_PUBLIC_ADDRESS, KEEPER_PUBLIC_ADDRESS, PUBLISHER_{1,2,3}_PUBLIC_ADDRESS
#
# Each wallet is topped up to a target balance (only the shortfall is sent), so running it again is harmless.
# Targets in MON, overridable: ADMIN_MON (20: deploy ≈ 11 + listing and series), KEEPER_MON (5: oracle pushes and
# settlement), PUBLISHER_MON (0.5: publishers only sign and never send transactions; this is spare).
# Refuses to run on anything but Monad testnet (chain 10143).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/indexer/.env}"
RPC_URL="${RPC_URL:-https://testnet-rpc.monad.xyz}"
ADMIN_MON="${ADMIN_MON:-20}"
KEEPER_MON="${KEEPER_MON:-5}"
PUBLISHER_MON="${PUBLISHER_MON:-0.5}"

DRY_RUN=0
YES=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --yes) YES=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
lower() { tr '[:upper:]' '[:lower:]'; }
# Read one KEY=value line without sourcing the file (nothing in it is executed).
get() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1 | tr -d '\r' | sed 's/^"\(.*\)"$/\1/; s/[[:space:]]*$//'; }
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }

command -v cast >/dev/null || die "cast (Foundry) is not installed"
[ -f "$ENV_FILE" ] || die "$ENV_FILE not found"

chain="$(cast chain-id --rpc-url "$RPC_URL")"
[ "$chain" = "10143" ] || die "RPC $RPC_URL is chain $chain, not Monad testnet (10143); refusing to send"

FUNDER_KEY="$(get ACCOUNT_WITH_TEST_FUNDS)"
FUNDER="$(get ADDRESS_WITH_TEST_FUNDS)"
[ -n "$FUNDER_KEY" ] || die "ACCOUNT_WITH_TEST_FUNDS is not set in $ENV_FILE"
is_addr "$FUNDER" || die "ADDRESS_WITH_TEST_FUNDS is not an address"
derived="$(cast wallet address --private-key "$FUNDER_KEY")"
[ "$(echo "$derived" | lower)" = "$(echo "$FUNDER" | lower)" ] || die "ACCOUNT_WITH_TEST_FUNDS does not belong to ADDRESS_WITH_TEST_FUNDS"

ROLES=(ADMIN KEEPER PUBLISHER_1 PUBLISHER_2 PUBLISHER_3)
target_for() { case "$1" in ADMIN) echo "$ADMIN_MON" ;; KEEPER) echo "$KEEPER_MON" ;; *) echo "$PUBLISHER_MON" ;; esac; }

to_wei() { cast to-wei "$1" ether; }
from_wei() { cast from-wei "$1" ether; }

echo "Monad testnet (10143) via $RPC_URL"
funder_wei="$(cast balance "$FUNDER" --rpc-url "$RPC_URL")"
echo "Funding wallet $FUNDER: $(from_wei "$funder_wei") MON"
echo

declare -a SEND_TO SEND_WEI SEND_ROLE
total=0
printf "%-12s %-42s %14s %14s %14s\n" ROLE ADDRESS "BALANCE" "TARGET" "SEND"
for role in "${ROLES[@]}"; do
  addr="$(get "${role}_PUBLIC_ADDRESS")"
  is_addr "$addr" || die "${role}_PUBLIC_ADDRESS is missing or not an address"
  [ "$(echo "$addr" | lower)" != "$(echo "$FUNDER" | lower)" ] || die "$role is the funding wallet itself"
  have="$(cast balance "$addr" --rpc-url "$RPC_URL")"
  want="$(to_wei "$(target_for "$role")")"
  send=0
  if [ "$(echo "$have < $want" | bc)" = "1" ]; then send="$(echo "$want - $have" | bc)"; fi
  printf "%-12s %-42s %14s %14s %14s\n" "$role" "$addr" "$(from_wei "$have")" "$(target_for "$role")" "$(from_wei "$send")"
  if [ "$send" != "0" ]; then
    SEND_TO+=("$addr"); SEND_WEI+=("$send"); SEND_ROLE+=("$role")
    total="$(echo "$total + $send" | bc)"
  fi
done
echo
echo "Total to send: $(from_wei "$total") MON (plus gas)"

[ "${#SEND_TO[@]}" -gt 0 ] || { echo "Every wallet is already at its target. Nothing to send."; exit 0; }
# Leave room for gas: about 0.01 MON per transfer is plenty on Monad testnet.
reserve="$(echo "${#SEND_TO[@]} * $(to_wei 0.01)" | bc)"
[ "$(echo "$funder_wei >= $total + $reserve" | bc)" = "1" ] || die "the funding wallet does not hold enough MON for this plan"

[ "$DRY_RUN" = "1" ] && { echo "Dry run: nothing sent."; exit 0; }
if [ "$YES" != "1" ]; then
  read -r -p "Send these transfers? [y/N] " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

for i in "${!SEND_TO[@]}"; do
  echo "Sending $(from_wei "${SEND_WEI[$i]}") MON to ${SEND_ROLE[$i]} ${SEND_TO[$i]}…"
  tx="$(cast send "${SEND_TO[$i]}" --value "${SEND_WEI[$i]}" --private-key "$FUNDER_KEY" --rpc-url "$RPC_URL" --json | sed -n 's/.*"transactionHash":"\(0x[0-9a-fA-F]*\)".*/\1/p')"
  echo "  tx $tx"
done

echo
echo "Balances now:"
for role in "${ROLES[@]}"; do
  addr="$(get "${role}_PUBLIC_ADDRESS")"
  printf "  %-12s %s  %s MON\n" "$role" "$addr" "$(cast balance "$addr" --ether --rpc-url "$RPC_URL")"
done
echo
echo "Testnet USDC is not sent by this script (the funding wallet holds none). The admin wallet needs it for the"
echo "insurance seed and keeper reserve: request it at https://faucet.circle.com (Monad testnet) for $(get ADMIN_PUBLIC_ADDRESS)."
