#!/usr/bin/env bash
# Testnet USDC from Circle's faucet API (POST https://api.circle.com/v1/faucet/drips), for testing on Monad testnet.
# Each drip is a fixed amount set by Circle (about 20 USDC on the Developer Console faucet) and Circle limits how
# many drips an account may request per day, so the script asks for ceil(target / drip) drips and stops at the first
# refusal. It never works around those limits.
#
#   scripts/circle-faucet.sh [amount_usdc] [address]        defaults: 100 USDC to the admin wallet
#
# Reads CIRCLE_KEY (the Circle API key, PREFIX:ID:SECRET) from ENV_FILE (default indexer/.env, git-ignored); the key
# is never printed. DRIP_USDC (default 20) is the amount one drip is expected to give.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/indexer/.env}"
TARGET="${1:-100}"
ADDRESS="${2:-0xbCe599D231e83594F47bFA2805bb8D8dF3D578bd}"
DRIP_USDC="${DRIP_USDC:-20}"
RPC_URL="${RPC_URL:-https://testnet-rpc.monad.xyz}"
USDC="0x534b2f3A21130d7a60830c2Df862319e593943A3" # Circle USDC on Monad testnet

die() { echo "error: $*" >&2; exit 1; }
KEY="$(grep -E '^CIRCLE_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')"
[ -n "$KEY" ] || die "CIRCLE_KEY is missing from $ENV_FILE"
[[ "$ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "not an address: $ADDRESS"

balance() { cast call "$USDC" "balanceOf(address)(uint256)" "$ADDRESS" --rpc-url "$RPC_URL" | awk '{print $1}'; }
usdc() { python3 -c "print(f'{int(\"$1\")/1e6:,.2f}')"; }

drips=$(( (TARGET + DRIP_USDC - 1) / DRIP_USDC ))
before=$(balance)
echo "Requesting ~$TARGET USDC for $ADDRESS on Monad testnet: $drips drip(s) of ~$DRIP_USDC USDC"
echo "Balance before: $(usdc "$before") USDC"

ok=0
for ((i = 1; i <= drips; i++)); do
  body=$(mktemp)
  code=$(curl -sS -o "$body" -w "%{http_code}" -X POST "https://api.circle.com/v1/faucet/drips" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: $(uuidgen | tr 'A-Z' 'a-z')" \
    -d "{\"address\":\"$ADDRESS\",\"blockchain\":\"MONAD-TESTNET\",\"usdc\":true,\"native\":false,\"eurc\":false}")
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    ok=$((ok + 1))
    echo "  drip $i/$drips: accepted"
  else
    echo "  drip $i/$drips: refused (HTTP $code) $(head -c 300 "$body")"
    rm -f "$body"
    break
  fi
  rm -f "$body"
  [ "$i" -lt "$drips" ] && sleep 3
done

[ "$ok" -gt 0 ] || die "no drip was accepted"
echo "Waiting for the USDC to arrive on-chain…"
for _ in $(seq 1 30); do
  now=$(balance)
  [ "$now" != "$before" ] && break
  sleep 5
done
sleep 10 # later drips can land a few blocks after the first
after=$(balance)
echo "Balance after:  $(usdc "$after") USDC (+$(usdc $((after - before))) USDC from $ok drip(s))"
