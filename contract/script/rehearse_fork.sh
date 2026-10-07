#!/usr/bin/env bash
# Rehearses a network deployment end to end on a local anvil fork of that network (DEPLOYMENT.md §4.2). Nothing is
# sent to the real network. Steps, each with the production script:
#   1. deployments/config/rehearsal-<network>.json: the network's config with throwaway anvil role holders
#   2. Deploy.s.sol (broadcast to the fork)          3. Verify.s.sol
#   4. RehearsalAssets.s.sol: stand-in tokens + settlement feeds, listing file (real Pyth feed ids)
#   5. ProposeListing.s.sol -> proposals file        6. every proposal sent by its role's key, in order
#   7. RehearsalSmoke.s.sol: a real signed Pyth update replayed from the live chain (when one is found), a signed
#      surface, an ATM weekly call written against the real Pyth spot
# Usage: script/rehearse_fork.sh <network> <rpc-url of that network>
#   e.g. script/rehearse_fork.sh monad-mainnet https://rpc.monad.xyz
# Role accounts (anvil mnemonic): 0 deployer + treasury, 1 governance, 2/3 publishers, 4 keeper, 5 writer,
# 6 oracleAdmin, 7 riskAdmin, 8 seriesCreator, 9 venueAdmin, 10 guardian, 11 council.
set -euo pipefail

NETWORK_NAME=${1:?usage: rehearse_fork.sh <network> <rpc-url>}
UPSTREAM=${2:?usage: rehearse_fork.sh <network> <rpc-url>}
PORT=${PORT:-8547}
RPC=http://127.0.0.1:$PORT
REHEARSAL=rehearsal-$NETWORK_NAME
MNEMONIC="test test test test test test test test test test test junk"
PYTH=0x2880aB155794e7179c9eE2e38200202908C17B43
ETH_USD_TOPIC=0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace

cd "$(dirname "$0")/.."
DEPLOYMENTS=../deployments
export FOUNDRY_BROADCAST=$DEPLOYMENTS/rehearsal-broadcast # keep fork runs out of broadcast/<chainId>/ (provenance)

key() { cast wallet private-key "$MNEMONIC" "$1"; }
addr() { cast wallet address --private-key "$(key "$1")"; }
step() { printf '\n== %s\n' "$*"; }

step "fork $NETWORK_NAME at $UPSTREAM"
anvil --fork-url "$UPSTREAM" --port "$PORT" --code-size-limit 131072 --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
FORK_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "chain $(cast chain-id --rpc-url "$RPC"), block $FORK_BLOCK"

step "1. rehearsal config"
python3 - "$DEPLOYMENTS/config/$NETWORK_NAME.json" "$DEPLOYMENTS/config/$REHEARSAL.json" \
  "$(addr 1)" "$(addr 10)" "$(addr 11)" "$(addr 7)" "$(addr 6)" "$(addr 8)" "$(addr 9)" <<'EOF'
import json, sys
src, dst, *a = sys.argv[1:]
c = json.load(open(src))
for k, v in zip(["governance", "guardian", "council", "riskAdmin", "oracleAdmin", "seriesCreator", "venueAdmin"], a):
    c[k] = v
c["_comment"] = "Fork rehearsal of " + src + " with throwaway anvil role holders (script/rehearse_fork.sh)."
json.dump(c, open(dst, "w"), indent=2)
EOF

step "2. deploy"
DEPLOYER_PRIVATE_KEY=$(key 0) NETWORK=$REHEARSAL \
  forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast --disable-code-size-limit -q
echo "manifest: $DEPLOYMENTS/$REHEARSAL.json"

step "3. verify"
NETWORK=$REHEARSAL forge script script/Verify.s.sol --rpc-url "$RPC" | grep verified

step "4. stand-in assets + listing file"
NETWORK=$REHEARSAL forge script script/rehearsal/RehearsalAssets.s.sol --rpc-url "$RPC" --broadcast -q

step "5. proposals"
NETWORK=$REHEARSAL LISTING=eth-usdc forge script script/ProposeListing.s.sol --rpc-url "$RPC" -q
PROPOSALS=$DEPLOYMENTS/$REHEARSAL.eth-usdc.proposals.json

step "6. execute proposals by role"
python3 - "$PROPOSALS" "$RPC" "$(key 1)" "$(key 6)" "$(key 7)" "$(key 0)" <<'EOF'
import json, subprocess, sys
path, rpc, gov, oracle, risk, treasury = sys.argv[1:]
keys = {"governance": gov, "oracleAdmin": oracle, "riskAdmin": risk, "treasury": treasury}
for c in json.load(open(path))["calls"]:
    out = subprocess.run(["cast", "send", c["to"], c["data"], "--private-key", keys[c["role"]], "--rpc-url", rpc,
                          "--json"], capture_output=True, text=True)
    ok = out.returncode == 0 and json.loads(out.stdout)["status"] == "0x1"
    print(f'{c["step"]:>3} {c["role"]:<12} {c["label"]:<48} {"ok" if ok else "FAILED"}')
    if not ok:
        sys.exit(out.stderr)
EOF

step "7. smoke against the real Pyth price"
# A real signed Pyth update: PYTH_UPDATE (hex, e.g. from Hermes with an API key) if given, else a fresh ETH/USD push
# taken from the live chain (mainnet has a pusher every ~30-60 s; testnet has none), replayed through Optara.
PYTH_UPDATE=${PYTH_UPDATE:-$(python3 - "$UPSTREAM" "$PYTH" "$ETH_USD_TOPIC" <<'EOF'
import json, subprocess, sys, time
rpc, pyth, topic = sys.argv[1:]
def cast(*a):
    return subprocess.run(["cast", *a, "--rpc-url", rpc], capture_output=True, text=True).stdout.strip()
# Wait (up to 3 min) for a push at most 15 s old, so the price is still within maxSpotAge (60 s) when used.
deadline = time.time() + 180
while time.time() < deadline:
    head = int(cast("block-number"))
    logs = json.loads(cast("logs", "--from-block", str(head - 99), "--to-block", str(head), "--address", pyth,
                           "--json", "", topic) or "[]")  # the RPC limits getLogs to 100 blocks
    if logs:
        block = json.loads(cast("block", str(int(logs[-1]["blockNumber"], 16)), "--json"))
        if time.time() - int(block["timestamp"], 16) <= 15:
            tx = json.loads(cast("tx", logs[-1]["transactionHash"], "--json"))
            sig = subprocess.run(["cast", "4byte", tx["input"][:10]], capture_output=True, text=True).stdout
            decoded = subprocess.run(["cast", "calldata-decode", sig.splitlines()[0], tx["input"], "--json"],
                                     capture_output=True, text=True).stdout
            print(json.loads(decoded)[0][0])
            break
    time.sleep(3)
EOF
)}
if [ -n "$PYTH_UPDATE" ]; then
  echo "replaying a real Pyth update (${#PYTH_UPDATE} hex chars)"
else
  echo "no fresh ETH/USD Pyth push on $NETWORK_NAME: the forked price must be fresh, or pass PYTH_UPDATE=<hex>"
fi
PYTH_UPDATE=$PYTH_UPDATE NETWORK=$REHEARSAL \
  forge script script/rehearsal/RehearsalSmoke.s.sol --rpc-url "$RPC" --broadcast \
  | grep -E 'rehearsal ok|writer equity|Pyth update'

step "rehearsal of $NETWORK_NAME passed"
