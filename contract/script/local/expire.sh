#!/usr/bin/env bash
# LOCAL ANVIL ONLY. Demo helper: moves chain time past the first seeded expiry (plus the 5-minute finalization
# delay) and publishes one MON/USDT observation on the MOCK feed, so the risk group can be finalized from the
# Settlement page (or by the indexer keeper). It never touches Optara state; finalization stays permissionless.
#
#   script/local/expire.sh 13        # MON settles at 13 USDT
#   script/local/expire.sh 7.5       # MON settles at 7.5 USDT (puts pay)
#
# The MON/USDe series of the same expiry gets no observation on purpose: it stays "awaiting final oracle price" and
# after 7 days of chain time turns ORACLE_STALLED, which shows the liveness behaviour.
set -euo pipefail

PRICE=${1:?usage: script/local/expire.sh <MON/USDT price, e.g. 13 or 7.5>}
RPC=${RPC_URL:-http://127.0.0.1:8545}
NET=${OPTARA_LOCAL_NETWORK:-local}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
MANIFEST="$ROOT/deployments/$NET.json"
MOCKS="$ROOT/deployments/$NET.mocks.json"
# anvil account 0 (the local deployer). MockAggregator.pushRound is open; this key only pays gas.
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

[ "$(cast chain-id --rpc-url "$RPC")" = "31337" ] || { echo "refusing: not a local anvil chain" >&2; exit 1; }

json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval('d'+sys.argv[2]))" "$1" "$2"; }
CORE=$(json "$MANIFEST" "['contracts']['OptaraCore']")
FEED=$(json "$MOCKS" "['feedMonUsdt']")
SERIES=$(json "$MOCKS" "['seededSeries'][0]")

# Series is a fully static struct, so its ABI encoding is inline words; word 3 is the expiry.
RAW=$(cast call "$CORE" "getSeries(bytes32)" "$SERIES" --rpc-url "$RPC")
EXPIRY=$(cast to-dec "0x${RAW:$((2 + 64 * 3)):64}")
NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
TARGET=$((EXPIRY + 301)) # past expiry + minFinalizationDelay (300 s in the local config)

if [ "$NOW" -lt "$TARGET" ]; then
  cast rpc anvil_setNextBlockTimestamp "$TARGET" --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
fi

# The observation in force at expiry: 60 s before it, inside the [expiry - 1h, expiry] window. 8-decimal feed.
ANSWER=$(cast parse-units "$PRICE" 8)
cast send "$FEED" "pushRound(int256,uint256)" "$ANSWER" $((EXPIRY - 60)) --private-key "$KEY" --rpc-url "$RPC" >/dev/null

echo "chain time  : $(cast block latest --field timestamp --rpc-url "$RPC") (expiry $EXPIRY)"
echo "MON/USDT    : $PRICE published at expiry-60s on mock feed $FEED"
echo "next        : open the Settlement page and press Finalize (or run the indexer with --keeper)"
