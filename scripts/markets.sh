#!/usr/bin/env bash
# Optara markets on Monad testnet or mainnet: deployment, listings, option rolls, Kuru books, verification and
# service wiring. Everything that differs between networks is configuration, never code:
#   deployments/config/<NETWORK>.markets.json   how this network runs (feeds, Kuru books, execution, expiries, services)
#   deployments/config/<NETWORK>.json           deployment (roles, Pyth, Kuru router)
#   deployments/config/<NETWORK>.<product>.json each product's listing
#
#   NETWORK=monad-testnet scripts/markets.sh <command> [products] [--yes]      (NETWORK defaults to monad-testnet)
#
#   deploy    fresh contracts (the previous manifest is archived), then the repo's deployment checks
#   list      per product: its settlement feed (push networks), then the listing calls
#   roll      options for every configured expiry and strike, at live-price strikes (and their Kuru books
#             where the network deploys them); re-run whenever the last set has expired
#   register  register Kuru books that Kuru deployed (networks with kuruBooks = none), from
#             deployments/<NETWORK>.kuru-books.json: {"books":[{"seriesId":"0x…","market":"0x…"}]}
#   verify    every contract of the deployment on Sourcify and MonadVision
#   wire      indexer config, publisher products and the contracts list; with --railway also the services'
#             Railway variables (non-secret only; keys stay as set)
#   all       deploy, list, roll, verify, wire
#
# products: comma separated (default: the profile's defaultProducts). --yes skips the confirmation before sending.
# execution = direct sends with the admin key; execution = propose sends nothing and writes the role holders'
# calls to deployments/<NETWORK>.*.proposals.json for their multisigs.
#
# Keys are read (never printed) from ENV_FILE (default indexer/.env, git-ignored): ACCOUNT_WITH_TEST_FUNDS or
# DEPLOYER_PRIVATE_KEY (deployer; must not hold a role), ADMIN_PRIVATE_KEY (direct execution), KEEPER_PRIVATE_KEY
# (push-feed pusher), HERMES_API_KEY (live prices; must cover every product's Pyth feeds).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/indexer/.env}"
NETWORK="${NETWORK:-monad-testnet}"
DEPLOY_DIR="$ROOT/deployments"
CONFIG="$DEPLOY_DIR/config/$NETWORK.json"
PROFILE="${PROFILE:-$DEPLOY_DIR/config/$NETWORK.markets.json}"
MANIFEST="$DEPLOY_DIR/$NETWORK.json"
SOURCIFY_SERVERS=("https://sourcify.dev/server/" "https://sourcify-api-monad.blockvision.org/")
[ -f "$CONFIG" ] || { echo "error: $CONFIG not found" >&2; exit 1; }
[ -f "$PROFILE" ] || { echo "error: $PROFILE not found" >&2; exit 1; }
CHAIN_ID=$(jq -r .chainId "$CONFIG")
RPC_URL="${RPC_URL:-$(jq -r .services.rpcUrl "$PROFILE")}"
HERMES_URL="${HERMES_URL:-$(jq -r .services.hermesUrl "$PROFILE")}"
KURU_ROUTER=$(jq -r .kuruRouter "$CONFIG")
FEEDS=$(jq -r .settlementFeeds "$PROFILE") # push | listing
BOOKS=$(jq -r .kuruBooks "$PROFILE")       # deploy | none
EXECUTION=$(jq -r .execution "$PROFILE")   # direct | propose

CMD="${1:-}"
shift || true
PRODUCTS=$(jq -r '.defaultProducts | join(",")' "$PROFILE")
YES=0
RAILWAY=0
for a in "$@"; do
  case "$a" in
    --yes) YES=1 ;;
    --railway) RAILWAY=1 ;;
    -*) echo "unknown option: $a" >&2; exit 2 ;;
    *) PRODUCTS="$a" ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }
get() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1 | tr -d '\r' | sed 's/^"\(.*\)"$/\1/; s/[[:space:]]*$//'; }
lower() { tr '[:upper:]' '[:lower:]'; }
cfg() { echo "$DEPLOY_DIR/config/$NETWORK.$1.json"; }
confirm() {
  [ "$YES" = 1 ] && return
  read -r -p "$1 [y/N] " ok
  [[ "$ok" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
}

# Network rules that protect mainnet whatever the profile says.
[ "$CHAIN_ID" != 143 ] || [ "$FEEDS" != push ] || die "settlementFeeds = push is refused on Monad mainnet"
[ "$EXECUTION" = direct ] || [ "$EXECUTION" = propose ] || die "execution must be direct or propose"
[ "$BOOKS" = deploy ] || [ "$BOOKS" = none ] || die "kuruBooks must be deploy or none"
[ "$BOOKS" != deploy ] || [ "$EXECUTION" = direct ] || die "kuruBooks = deploy needs execution = direct"

preflight() {
  for t in forge cast jq python3 curl; do command -v $t >/dev/null || die "$t is not installed"; done
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found"
  [ "$(cast chain-id --rpc-url "$RPC_URL")" = "$CHAIN_ID" ] || die "$RPC_URL is not chain $CHAIN_ID ($NETWORK)"
  DEPLOYER_KEY="$(get DEPLOYER_PRIVATE_KEY)"
  [ -n "$DEPLOYER_KEY" ] || DEPLOYER_KEY="$(get ACCOUNT_WITH_TEST_FUNDS)"
  ADMIN_KEY="$(get ADMIN_PRIVATE_KEY)"
  KEEPER_KEY="$(get KEEPER_PRIVATE_KEY)"
  HERMES_KEY="$(get HERMES_API_KEY)"
  [ -n "$HERMES_KEY" ] || die "HERMES_API_KEY is missing from $ENV_FILE"
  DEPLOYER=""; ADMIN=""; KEEPER=""
  [ -n "$DEPLOYER_KEY" ] && DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_KEY")"
  [ -n "$KEEPER_KEY" ] && KEEPER="$(cast wallet address --private-key "$KEEPER_KEY")"
  if [ "$EXECUTION" = direct ]; then
    [ -n "$ADMIN_KEY" ] || die "execution = direct needs ADMIN_PRIVATE_KEY"
    ADMIN="$(cast wallet address --private-key "$ADMIN_KEY")"
    roles=$(jq -r '[.governance,.guardian,.council,.riskAdmin,.oracleAdmin,.seriesCreator,.venueAdmin] | unique | join(",")' "$CONFIG")
    [ "$(echo "$roles" | lower)" = "$(echo "$ADMIN" | lower)" ] || die "execution = direct needs every role in $NETWORK.json to be the admin key's address ($ADMIN)"
  fi
  echo "$NETWORK (chain $CHAIN_ID): feeds=$FEEDS books=$BOOKS execution=$EXECUTION"
}

# Pyth base / quote (quote may be empty) scaled to `decimals`. Fails if the Hermes key lacks a feed.
pyth_ratio() {
  local base="$1" quote="$2" decimals="$3" ids body code
  ids="ids%5B%5D=$base"
  [ -n "$quote" ] && [ "$quote" != null ] && ids="$ids&ids%5B%5D=$quote" || quote=""
  body=$(curl -s -m 20 -w '\n%{http_code}' -H "Authorization: Bearer $HERMES_KEY" "$HERMES_URL/v2/updates/price/latest?$ids&parsed=true")
  code=$(echo "$body" | tail -1)
  [ "$code" = 200 ] || die "Hermes $code for feeds $base $quote: $(echo "$body" | head -1 | cut -c1-160)"
  echo "$body" | sed '$d' | python3 -c '
import json,sys
b,q,d=sys.argv[1].lower().removeprefix("0x"),sys.argv[2].lower().removeprefix("0x"),int(sys.argv[3])
px={p["id"].lower():(int(p["price"]["price"]),int(p["price"]["expo"])) for p in json.load(sys.stdin)["parsed"]}
bp,be=px[b]; qp,qe=px[q] if q else (1,0)
e=d+be-qe
print(bp*10**e//qp if e>=0 else bp//(qp*10**-e))' "$base" "$quote" "$decimals"
}

# Spot of a product (base / quote) scaled to `decimals`, from the product's own spot provider: signed price packages
# (listings with spotSource "redstone", the on-chain format: median of the authorized signers, as LiveSpotOracle
# computes it) from the network's price node (config `priceNode`, else RedStone's gateway), or Pyth.
spot_ratio() {
  local p="$1" decimals="$2" c; c="$(cfg "$p")"
  if [ "$(jq -r '.spotSource // "pyth"' "$c")" = redstone ]; then
    local service url signers threshold
    service=$(jq -r '.redstone.dataServiceId // "optara"' "$CONFIG")
    url=$(jq -r '.priceNode.urls[0] // "https://oracle-gateway-1.a.redstone.finance"' "$CONFIG")
    signers=$(jq -c '.priceNode.signers // .redstone.signers' "$CONFIG")
    threshold=$(jq -r '.priceNode.threshold // .redstone.threshold' "$CONFIG")
    curl -s -m 20 "$url/data-packages/latest/$service" | python3 -c '
import json,sys
from statistics import median
gw=json.load(sys.stdin); signers={s.lower() for s in json.loads(sys.argv[1])}; need=int(sys.argv[2]); d=int(sys.argv[5])
if "error" in gw: sys.exit("price node: " + str(gw["error"]))
def px(name):
    if not name: return 1.0
    v=[p["dataPoints"][0]["value"] for p in gw.get(name,[]) if p["signerAddress"].lower() in signers]
    if len(v)<need: sys.exit(f"price node: only {len(v)} authorized signers for {name}")
    return median(v)
print(int(px(sys.argv[3])/px(sys.argv[4])*10**d))' "$signers" "$threshold" "$(jq -r .redstoneBaseFeed "$c")" "$(jq -r '.redstoneQuoteFeed // ""' "$c")" "$decimals"
  else
    pyth_ratio "$(jq -r .pythBaseFeed "$c")" "$(jq -r .pythQuoteFeed "$c")" "$decimals"
  fi
}

# The feed ids the keeper reads for a product's settlement push feed: named feeds (bytes32, signed price packages) or Pyth ids.
feed_ids() {
  local c; c="$(cfg "$1")"
  if [ "$(jq -r '.spotSource // "pyth"' "$c")" = redstone ]; then
    printf '%s %s' "$(cast format-bytes32-string "$(jq -r .redstoneBaseFeed "$c")")"       "$( [ -n "$(jq -r '.redstoneQuoteFeed // ""' "$c")" ] && cast format-bytes32-string "$(jq -r .redstoneQuoteFeed "$c")" || echo "")"
  else
    printf '%s %s' "$(jq -r .pythBaseFeed "$c")" "$(jq -r .pythQuoteFeed "$c")"
  fi
}

# Role calls: direct sends them from the admin key; propose leaves the file for the multisigs.
run_calls() {
  local file="$1" n i to data value label role
  n=$(jq '.calls | length' "$file")
  if [ "$EXECUTION" = propose ]; then
    echo "   $n calls written to ${file#$ROOT/} for the role holders' multisigs (nothing sent):"
    jq -r '.calls | group_by(.role)[] | "     \(.[0].role): \(length)"' "$file"
    return
  fi
  for ((i = 0; i < n; i++)); do
    to=$(jq -r ".calls[$i].to" "$file"); data=$(jq -r ".calls[$i].data" "$file")
    value=$(jq -r ".calls[$i].value" "$file"); label=$(jq -r ".calls[$i].label" "$file"); role=$(jq -r ".calls[$i].role" "$file")
    [ "$role" = treasury ] && die "call $((i + 1)) needs the treasury; list with bootstrapFromFees or execution = propose"
    printf '  %2d/%d %-13s %s … ' $((i + 1)) "$n" "$role" "$label"
    cast send "$to" "$data" --value "$value" --private-key "$ADMIN_KEY" --rpc-url "$RPC_URL" --json >/dev/null || die "call $((i + 1)) ($label) failed"
    echo ok
  done
}

# Expiry specs → unix times, each at least 1 h 5 min out (createSeries needs ≥ 1 h when it executes).
expiry_times() {
  jq -c .expiries "$PROFILE" | python3 -c '
import json,sys,datetime as dt
now=dt.datetime.now(dt.timezone.utc); floor=now+dt.timedelta(hours=1,minutes=5); out=[]
days=["mon","tue","wed","thu","fri","sat","sun"]
for s in json.load(sys.stdin):
    if s.startswith("+") and s.endswith("h"): t=now+dt.timedelta(hours=float(s[1:-1]),minutes=5)
    else:
        kind,*rest=s.split("@"); hh,mm=map(int,rest[-1].split(":"))
        t=now.replace(hour=hh,minute=mm,second=0,microsecond=0)
        if kind=="daily":
            while t<floor: t+=dt.timedelta(days=1)
        elif kind=="weekly":
            want=days.index(rest[0].lower()[:3])
            t+=dt.timedelta(days=(want-t.weekday())%7)
            while t<floor: t+=dt.timedelta(days=7)
        else: sys.exit(f"bad expiry spec {s}")
    out.append(int(t.timestamp()))
print(",".join(map(str,sorted(set(out)))))'
}

cmd_deploy() {
  step "Fresh deployment to $NETWORK (Kuru router $KURU_ROUTER)"
  [ -n "$DEPLOYER_KEY" ] || die "no deployer key (DEPLOYER_PRIVATE_KEY or ACCOUNT_WITH_TEST_FUNDS)"
  echo "Deployer $DEPLOYER: $(cast balance "$DEPLOYER" --ether --rpc-url "$RPC_URL") MON (the deploy costs ~12)"
  confirm "Deploy a new set of Optara contracts to $NETWORK?"
  if [ -f "$MANIFEST" ]; then
    mkdir -p "$DEPLOY_DIR/archive"
    local block f; block=$(jq -r .deployedAtBlock "$MANIFEST")
    for f in "$MANIFEST" "$DEPLOY_DIR/$NETWORK".*.proposals.json "$DEPLOY_DIR/$NETWORK.series.json" "$DEPLOY_DIR/$NETWORK.kuru-books.json"; do
      [ -f "$f" ] && mv "$f" "$DEPLOY_DIR/archive/$(basename "$f" .json).$block.json"
    done
    echo "archived the previous deployment (block $block) to deployments/archive/"
  fi
  (cd "$ROOT/contract" && NETWORK=$NETWORK DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY" \
    forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --slow --disable-code-size-limit 2>&1 | grep -E "Error|error|ONCHAIN EXECUTION" || true)
  [ -f "$MANIFEST" ] || die "Deploy.s.sol did not write $MANIFEST"
  # Deploy.s.sol writes the manifest while simulating, so check the contracts it names really exist on-chain.
  [ "$(cast code "$(jq -r .upgradeAdmin "$MANIFEST")" --rpc-url "$RPC_URL")" != 0x ] || die "the deployment was not broadcast (no code at the manifest's UpgradeAdmin)"
  (cd "$ROOT/contract" && NETWORK=$NETWORK forge script script/Verify.s.sol --rpc-url "$RPC_URL" 2>&1 | grep -E "verified|Error|error" | tail -3 || true)
  echo "deployed at block $(jq -r .deployedAtBlock "$MANIFEST"); Kuru adapter $(jq -r .kuruAdapter "$MANIFEST")"
}

cmd_list() {
  [ -f "$MANIFEST" ] || die "no $MANIFEST: run deploy first"
  step "Listing $PRODUCTS on $NETWORK"
  confirm "List $PRODUCTS on $NETWORK ($EXECUTION)?"
  local p sym base quote feed price
  for p in ${PRODUCTS//,/ }; do
    [ -f "$(cfg "$p")" ] || die "$(cfg "$p") not found"
    [ "$(jq -r --arg p "$p" '.products[$p].vol // "null"' "$PROFILE")" != null ] || die "$p has no vol source in $NETWORK.markets.json"
    sym=$(jq -r .underlyingSymbol "$(cfg "$p")")
    read -r base quote <<< "$(feed_ids "$p")"
    price=$(spot_ratio "$p" 8) # the product's spot provider must serve it before anything is sent
    echo "-- $p: $sym/$(jq -r .assetSymbol "$(cfg "$p")") $(python3 -c "print($price/1e8)")"
    if [ "$FEEDS" = push ]; then
      [ -n "$KEEPER" ] || die "push feeds need KEEPER_PRIVATE_KEY (the pusher)"
      feed=$(cd "$ROOT/contract" && forge create src/testnet/TestnetPushFeed.sol:TestnetPushFeed --rpc-url "$RPC_URL" \
        --private-key "$DEPLOYER_KEY" --broadcast --json --constructor-args 8 "$sym / USDC (Optara testnet push)" "$ADMIN" "$KEEPER" \
        | jq -r .deployedTo)
      cast send "$feed" "push(int256)" "$price" --private-key "$KEEPER_KEY" --rpc-url "$RPC_URL" --json >/dev/null
      echo "   settlement feed $feed (first round pushed)"
      jq --arg f "$feed" '.settlement.primary.feed = $f' "$(cfg "$p")" > "$(cfg "$p").tmp" && mv "$(cfg "$p").tmp" "$(cfg "$p")"
      jq --arg f "$feed" --arg b "$base" --arg q "$quote" --arg l "$sym / USDC" \
        '.extra.testnetFeeds = ((.extra.testnetFeeds // []) | map(select(.label != $l)) + [{feed: $f, base: $b, quote: $q, label: $l}])' \
        "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    fi
    (cd "$ROOT/contract" && NETWORK=$NETWORK LISTING=$p forge script script/ProposeListing.s.sol --rpc-url "$RPC_URL" 2>&1 \
      | grep -E "Error|error" || true)
    run_calls "$DEPLOY_DIR/$NETWORK.$p.proposals.json"
  done
}

cmd_roll() {
  [ -f "$MANIFEST" ] || die "no $MANIFEST: run deploy first"
  local expiries offsets i=0 p env=()
  expiries=$(expiry_times); offsets=$(jq -r '.strikeOffsetsBps | join(",")' "$PROFILE")
  step "Rolling $PRODUCTS: expiries $(python3 -c "import sys,datetime as d;print(', '.join(d.datetime.fromtimestamp(int(t),d.timezone.utc).strftime('%d %b %H:%M') for t in sys.argv[1].split(',')))" "$expiries") UTC; strikes spot ${offsets} bps"
  for p in ${PRODUCTS//,/ }; do
    local w; w=$(spot_ratio "$p" 18)
    echo "-- $p spot $(python3 -c "print($w/1e18)")"
    env+=("SPOT_WAD_$i=$w"); i=$((i + 1))
  done
  [ "$EXECUTION" = direct ] && echo "Admin $ADMIN: $(cast balance "$ADMIN" --ether --rpc-url "$RPC_URL") MON"
  confirm "Create these options on $NETWORK ($EXECUTION, Kuru books: $BOOKS)?"
  local bc=(); [ "$EXECUTION" = direct ] && bc=(--broadcast --slow)
  local series="$DEPLOY_DIR/$NETWORK.series.json" prev=""
  [ -f "$series" ] && prev=$(cat "$series") # the roll rewrites the file; other products' entries are kept below
  (cd "$ROOT/contract" && env "${env[@]}" NETWORK=$NETWORK PRODUCTS="$PRODUCTS" EXPIRIES="$expiries" STRIKE_OFFSETS_BPS="$offsets" \
    KURU_BOOKS=$BOOKS KURU_ROUTER=$KURU_ROUTER EXECUTION=$EXECUTION ADMIN_PRIVATE_KEY="${ADMIN_KEY:-0x01}" \
    forge script script/RollSeries.s.sol --rpc-url "$RPC_URL" --disable-code-size-limit ${bc[@]+"${bc[@]}"} 2>&1 | grep -E "listed|proposal|Error|error" || true)
  [ -f "$series" ] || die "the roll wrote no series file"
  # forge writes the file while simulating: in direct mode, make sure the options really exist on-chain
  if [ "$EXECUTION" = direct ] && [ "$(cast code "$(jq -r '.series[-1].wrapper' "$series")" --rpc-url "$RPC_URL")" = 0x ]; then
    [ -n "$prev" ] && echo "$prev" > "$series"
    die "the roll was not broadcast (no option token on-chain); nothing changed, run it again"
  fi
  if [ -n "$prev" ]; then # add the new options to the list: every earlier option (of any product) is kept
    echo "$prev" | jq --slurpfile new "$series" \
      '$new[0] + {series: ((.series + $new[0].series) | unique_by(.seriesId) | sort_by(.expiry, .listing, .type, (.strikeWad | tonumber)))}' \
      > "$series.tmp" && mv "$series.tmp" "$series"
  fi
  [ "$EXECUTION" = propose ] && run_calls "$DEPLOY_DIR/$NETWORK.roll.proposals.json"
  [ "$BOOKS" = none ] && echo "Kuru books: send Kuru the option tokens in deployments/$NETWORK.series.json; register them with: markets.sh register"
  return 0
}

cmd_register() {
  local file="$DEPLOY_DIR/$NETWORK.kuru-books.json" out="$DEPLOY_DIR/$NETWORK.register.proposals.json"
  [ -f "$file" ] || die "$file not found ({\"books\":[{\"seriesId\":\"0x…\",\"market\":\"0x…\"}]})"
  local venues; venues=$(jq -r .proxies.VenueRegistry.proxy "$MANIFEST")
  step "Registering $(jq '.books | length' "$file") Kuru books"
  confirm "Register them ($EXECUTION)?"
  jq -c --arg v "$venues" --arg from "$(jq -r .roles.venueAdmin "$MANIFEST")" '.books[]' "$file" | while read -r b; do
    jq -n --argjson b "$b" --arg v "$venues" --arg from "$(jq -r .roles.venueAdmin "$MANIFEST")" \
      --arg data "$(cast calldata 'registerMarket(bytes32,address,bytes32,bytes)' "$(cast keccak KURU)" "$(echo "$b" | jq -r .market)" "$(echo "$b" | jq -r .seriesId)" 0x)" \
      '{role: "venueAdmin", from: $from, to: $v, value: 0, data: $data, label: "register Kuru book \($b.market)"}'
  done | jq -s --arg n "$NETWORK" '{network: $n, calls: .}' > "$out"
  run_calls "$out"
}

cmd_verify() {
  [ -f "$MANIFEST" ] || die "no $MANIFEST"
  step "Verifying $NETWORK on Sourcify and MonadVision"
  local list; list=$(mktemp)
  jq -r '.transactions[] | select(.transactionType=="CREATE") | "\(.contractAddress) \(.contractName)"' \
    "$ROOT/contract/broadcast/Deploy.s.sol/$CHAIN_ID/run-latest.json" > "$list"
  jq -r '.proxies[] | "\(.proxy) TransparentUpgradeableProxy\n\(.proxyAdmin) ProxyAdmin"' "$MANIFEST" >> "$list"
  jq -r '(.extra.testnetFeeds // [])[] | "\(.feed) TestnetPushFeed"' "$MANIFEST" >> "$list"
  local addr name src server ok=0 total res
  total=$(sort -u "$list" | wc -l | tr -d ' ')
  while read -r addr name; do
    src=$(cd "$ROOT/contract" && find src lib/openzeppelin-contracts/contracts -name "$name.sol" | head -1)
    [ -n "$src" ] || { echo "  ? $name $addr: source not found"; continue; }
    res=""
    for server in "${SOURCIFY_SERVERS[@]}"; do
      if (cd "$ROOT/contract" && forge verify-contract "$addr" "$src:$name" --chain "$CHAIN_ID" --verifier sourcify \
        --verifier-url "$server" --rpc-url "$RPC_URL" --watch < /dev/null 2>&1 | grep -qE 'match|already verified'); then
        res="$res ✓"
      else res="$res ✗"; fi
    done
    echo "  $res  $name $addr"
    [ "$res" = " ✓ ✓" ] && ok=$((ok + 1))
  done < <(sort -u "$list")
  rm -f "$list"
  echo "verified on both: $ok/$total (option tokens are EIP-1167 clones of the verified ExternalOptionWrapper; Kuru books are Kuru's)"
}

cmd_wire() {
  [ -f "$MANIFEST" ] || die "no $MANIFEST"
  local block schema out p rows="[]" sym vol
  block=$(jq -r .deployedAtBlock "$MANIFEST")
  schema="$(echo "$NETWORK" | tr '-' '_')_$block" # one Postgres schema per deployment: a new one indexes fresh, no reset
  step "Wiring services to $NETWORK block $block"
  (cd "$ROOT/indexer" && npx tsx scripts/gen-config.ts "$NETWORK")
  out="$ROOT/publisher/products.$NETWORK.json"
  for p in ${PRODUCTS//,/ }; do
    vol=$(jq -r --arg p "$p" '.products[$p].vol // "null"' "$PROFILE")
    [ "$vol" != null ] || die "$p has no vol source in $NETWORK.markets.json"
    sym=$(jq -r .underlyingSymbol "$(cfg "$p")")
    rows=$(echo "$rows" | jq --arg s "$sym/$(jq -r .assetSymbol "$(cfg "$p")")" --arg u "$(jq -r .underlying "$(cfg "$p")")" \
      --arg a "$(jq -r .asset "$(cfg "$p")")" --arg i "$vol" '. + [{symbol: $s, underlying: $u, settlementAsset: $a, inputs: $i}]')
  done
  echo "$rows" | jq . > "$out"
  echo "wrote publisher/products.$NETWORK.json: $(jq -r 'map(.symbol) | join(", ")' "$out")"
  python3 "$ROOT/scripts/gen-contracts-doc.py" "$NETWORK"
  if [ "$RAILWAY" = 1 ]; then
    command -v railway >/dev/null || die "railway CLI is not installed"
    local s
    s=$(jq -r .services.railway.publisher "$PROFILE")
    railway variables -s "$s" --skip-deploys --set "CHAIN_ID=$CHAIN_ID" --set "MANIFEST=$NETWORK" --set "RPC_URL=$RPC_URL" \
      --set "PRODUCTS=products.$NETWORK.json" --set "HERMES_URL=$HERMES_URL" \
      $(jq -r '.services.publisher | to_entries[] | "--set \(.key)=\(.value)"' "$PROFILE") | tail -1
    s=$(jq -r .services.railway.keepers "$PROFILE")
    railway variables -s "$s" --skip-deploys --set "CHAIN_ID=$CHAIN_ID" --set "MANIFEST=$NETWORK" --set "RPC_URL=$RPC_URL" \
      --set "HERMES_URL=$HERMES_URL" --set "KEEPER_MODES=$(jq -r .services.keepers.KEEPER_MODES "$PROFILE")" \
      $(jq -r '.services.keepers | del(.KEEPER_MODES) | to_entries[] | "--set \(.key)=\(.value)"' "$PROFILE") | tail -1
    s=$(jq -r .services.railway.indexer "$PROFILE")
    railway variables -s "$s" --skip-deploys --set "ENVIO_CONFIG=config.$NETWORK.yaml" --set "ENVIO_PG_SCHEMA=$schema" | tail -1
    s=$(jq -r .services.railway.indexerApi "$PROFILE")
    railway variables -s "$s" --skip-deploys --set "CHAIN_ID=$CHAIN_ID" --set "MANIFEST=$NETWORK" --set "RPC_URL=$RPC_URL" \
      --set "ENVIO_PG_SCHEMA=$schema" | tail -1
    echo "Railway variables set (deploys on your next push). Keys are unchanged: set the $NETWORK keys yourself."
  fi
  echo "Frontend (Cloudflare build variables): $(jq -r '.services.frontend | to_entries | map("\(.key)=\(.value)") | join("  ")' "$PROFILE")"
  echo "Commit and push to deploy."
}

case "$CMD" in
  deploy) preflight; cmd_deploy ;;
  list) preflight; cmd_list ;;
  roll) preflight; cmd_roll ;;
  register) preflight; cmd_register ;;
  verify) cmd_verify ;;
  wire) cmd_wire ;;
  all) preflight; cmd_deploy; YES=1 cmd_list; YES=1 cmd_roll; cmd_verify; cmd_wire ;;
  *) sed -n '2,27p' "$0"; exit 2 ;;
esac
