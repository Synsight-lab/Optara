#!/usr/bin/env bash
# Rehearses the whole deployment runbook and one full option lifecycle on a LOCAL Anvil chain, asserting every
# expected result. Local only: it uses Anvil's public test accounts and mock tokens.
#
#   ./script/local/rehearsal.sh
#
# Requires foundry (forge, cast, anvil).
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT=8546
RPC=http://127.0.0.1:$PORT
MNEMONIC="test test test test test test test test test test test junk"
key() { cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$1"; }
addr() { cast wallet address --private-key "$(key "$1")"; }

# account roles (anvil indices)
DEPLOYER_KEY=$(key 0);  DEPLOYER=$(addr 0)   # starts as ADMIN
ALICE_KEY=$(key 1);     ALICE=$(addr 1)      # writer, and creates the series with no role
BOB_KEY=$(key 2);       BOB=$(addr 2)        # buyer
PAUSER_KEY=$(key 3);    PAUSER=$(addr 3)
TREASURY=$(addr 4)
MULTISIG_KEY=$(key 5);  MULTISIG=$(addr 5)   # the ADMIN after handover
KEEPER_KEY=$(key 6);    KEEPER=$(addr 6)     # no role at all

ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; exit 1; }
expect_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1: got '$2' expected '$3'"; }
expect_revert() { # description, expected error name, command...
  local d=$1 e=$2; shift 2
  if out=$("$@" 2>&1); then fail "$d: should have reverted"; fi
  echo "$out" | grep -q "$e" && pass "$d reverts with $e" || fail "$d: wrong revert: $(echo "$out" | head -2)"
}
num() { awk '{print $1}'; }

pkill -f "anvil --port $PORT" 2>/dev/null || true
anvil --port $PORT --silent >/tmp/anvil-rehearsal.log 2>&1 &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 3

echo "== 1. deploy mock tokens and feed (local only) =="
out=$(forge script script/local/DeployMocks.s.sol --rpc-url $RPC --broadcast --private-key "$DEPLOYER_KEY" 2>&1)
WMON=$(echo "$out" | awk '/WMON/{print $2}' | tail -1); USDC=$(echo "$out" | awk '/USDC/{print $2}' | tail -1); FEED=$(echo "$out" | awk '/FEED/{print $2}' | tail -1)

echo "== 2. deploy the protocol =="
out=$(FEE_RECIPIENT=$TREASURY PAUSER=$PAUSER forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key "$DEPLOYER_KEY" 2>&1)
FACTORY=$(echo "$out" | awk '/OptionSeriesFactory   /{print $2}' | tail -1)
GUARD=$(echo "$out" | awk '/PremiumExecutionGuard /{print $2}' | tail -1)
[ -n "$FACTORY" ] && pass "factory deployed at $FACTORY" || fail "deploy"
expect_eq "deployer is ADMIN before handover" "$(cast call $FACTORY 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $DEPLOYER --rpc-url $RPC)" "true"

echo "== 3. configure the pair (allowlist, approved feed, cap) =="
FACTORY=$FACTORY UNDERLYING=$WMON QUOTE=$USDC FEED=$FEED MAX_AGE=3600 STRIKE_STEP=500000000000000000 MAX_SHORT=100000000000000000000 \
  forge script script/ConfigurePair.s.sol --rpc-url $RPC --broadcast --private-key "$DEPLOYER_KEY" >/dev/null 2>&1
expect_eq "WMON allowlisted" "$(cast call $FACTORY 'allowedAsset(address)(bool)' $WMON --rpc-url $RPC)" "true"

echo "== 4. hand the ADMIN role to the multisig and renounce the deployer's =="
FACTORY=$FACTORY NEW_ADMIN=$MULTISIG forge script script/HandOverAdmin.s.sol --rpc-url $RPC --broadcast --private-key "$DEPLOYER_KEY" >/dev/null 2>&1
expect_eq "multisig is ADMIN" "$(cast call $FACTORY 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $MULTISIG --rpc-url $RPC)" "true"
expect_eq "deployer is no longer ADMIN" "$(cast call $FACTORY 'hasRole(bytes32,address)(bool)' $ADMIN_ROLE $DEPLOYER --rpc-url $RPC)" "false"
expect_revert "the old deployer cannot change settings" "AccessControlUnauthorizedAccount" \
  cast send $FACTORY "setFeeRecipient(address)" $DEPLOYER --rpc-url $RPC --private-key "$DEPLOYER_KEY"

echo "== 5. a stranger with no role creates a series =="
NOW=$(cast block latest --rpc-url $RPC -f timestamp)
EXPIRY=$(( (NOW/86400 + 3) * 86400 + 28800 ))          # 08:00 UTC, three days out
PARAMS="(0,$WMON,$USDC,10000000000000000000,$EXPIRY,$FEED)"
SIG="createSeries((uint8,address,address,uint256,uint64,address))"
cast send $FACTORY "$SIG" "$PARAMS" --rpc-url $RPC --private-key "$ALICE_KEY" >/dev/null
ID=$(cast call $FACTORY "computeSeriesId((uint8,address,address,uint256,uint64,address))(bytes32)" "$PARAMS" --rpc-url $RPC)
VAULT=$(cast call $FACTORY "vaultOf(bytes32)(address)" $ID --rpc-url $RPC)
expect_eq "series is official" "$(cast call $FACTORY 'isOptionToken(address)(bool)' $VAULT --rpc-url $RPC)" "true"
expect_eq "generated name" "$(cast call $VAULT 'name()(string)' --rpc-url $RPC)" '"Optara WMON/USDC Call #1"'
expect_revert "creating it again" "DuplicateSeries" cast send $FACTORY "$SIG" "$PARAMS" --rpc-url $RPC --private-key "$ALICE_KEY"
expect_revert "a feed that is not the approved one" "FeedNotApproved" \
  cast send $FACTORY "$SIG" "(0,$WMON,$USDC,11000000000000000000,$EXPIRY,$USDC)" --rpc-url $RPC --private-key "$ALICE_KEY"
expect_revert "an expiry off the daily slot" "InvalidExpiry" \
  cast send $FACTORY "$SIG" "(0,$WMON,$USDC,11000000000000000000,$((EXPIRY+60)),$FEED)" --rpc-url $RPC --private-key "$ALICE_KEY"

echo "== 6. Alice writes 5 options and Bob receives them =="
cast send $WMON "mint(address,uint256)" $ALICE 6000000000000000000 --rpc-url $RPC --private-key "$DEPLOYER_KEY" >/dev/null
cast send $WMON "approve(address,uint256)" $VAULT 6000000000000000000 --rpc-url $RPC --private-key "$ALICE_KEY" >/dev/null
cast send $VAULT "mint(uint256,address)" 5000000000000000000 $BOB --rpc-url $RPC --private-key "$ALICE_KEY" >/dev/null
expect_eq "collateral locked (5 MON, fee on top)" "$(cast call $VAULT 'collateralLocked()(uint256)' --rpc-url $RPC | num)" "5000000000000000000"
expect_eq "mint fee accrued (10 bps)" "$(cast call $VAULT 'accruedFees()(uint256)' --rpc-url $RPC | num)" "5000000000000000"
expect_eq "Bob holds the tokens" "$(cast call $VAULT 'balanceOf(address)(uint256)' $BOB --rpc-url $RPC | num)" "5000000000000000000"

echo "== 7. freeze and unfreeze minting =="
expect_revert "a stranger cannot freeze" "Unauthorized" cast send $VAULT "setMintPaused(bool)" true --rpc-url $RPC --private-key "$KEEPER_KEY"
cast send $VAULT "setMintPaused(bool)" true --rpc-url $RPC --private-key "$PAUSER_KEY" >/dev/null
expect_revert "minting while frozen" "MintPaused" cast send $VAULT "mint(uint256,address)" 1000000000000000000 $BOB --rpc-url $RPC --private-key "$ALICE_KEY"
expect_revert "the pauser cannot unfreeze" "Unauthorized" cast send $VAULT "setMintPaused(bool)" false --rpc-url $RPC --private-key "$PAUSER_KEY"
cast send $VAULT "setMintPaused(bool)" false --rpc-url $RPC --private-key "$MULTISIG_KEY" >/dev/null
expect_eq "the admin unfroze it" "$(cast call $VAULT 'mintPaused()(bool)' --rpc-url $RPC)" "false"

echo "== 8. expiry: the price at expiry is 12.50 =="
R2=18446744073709551618; R3=18446744073709551619            # (phase 1, round 2) and (phase 1, round 3)
cast send $FEED "push(uint80,int256,uint256)" $R2 1250000000 $((EXPIRY-100)) --rpc-url $RPC --private-key "$DEPLOYER_KEY" >/dev/null
cast send $FEED "push(uint80,int256,uint256)" $R3 1300000000 $((EXPIRY+100)) --rpc-url $RPC --private-key "$DEPLOYER_KEY" >/dev/null
expect_revert "settling before expiry" "NotExpired" cast send $VAULT "settle((uint80,uint80))" "($R2,$R3)" --rpc-url $RPC --private-key "$KEEPER_KEY"
NOW=$(cast block latest --rpc-url $RPC -f timestamp)
cast rpc evm_increaseTime $((EXPIRY+3600-NOW)) --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
expect_revert "minting after expiry" "Expired" cast send $VAULT "mint(uint256,address)" 1000000000000000000 $BOB --rpc-url $RPC --private-key "$ALICE_KEY"
expect_revert "a forged proof (round R3 named as in force, but its successor R3+1 was never published)" \
  "SettlementAnchorSuccessorUnavailable" \
  cast send $VAULT "settle((uint80,uint80))" "($R3,$((R3+1)))" --rpc-url $RPC --private-key "$KEEPER_KEY"

echo "== 9. a keeper with no role settles =="
cast send $VAULT "settle((uint80,uint80))" "($R2,$R3)" --rpc-url $RPC --private-key "$KEEPER_KEY" >/dev/null
expect_eq "settled" "$(cast call $VAULT 'settled()(bool)' --rpc-url $RPC)" "true"
expect_eq "price is the round in force (12.50), not the later 13.00" "$(cast call $VAULT 'settlementPrice()(uint256)' --rpc-url $RPC | num)" "12500000000000000000"
expect_eq "buyer payout rate" "$(cast call $VAULT 'buyerPayoutRate()(uint256)' --rpc-url $RPC | num)" "200000000000000000"
expect_eq "writer residual rate" "$(cast call $VAULT 'writerResidualRate()(uint256)' --rpc-url $RPC | num)" "800000000000000000"
expect_revert "settling twice" "AlreadySettled" cast send $VAULT "settle((uint80,uint80))" "($R2,$R3)" --rpc-url $RPC --private-key "$KEEPER_KEY"

echo "== 10. the keeper pays everyone in ONE call (gas estimated by cast, no manual limit) =="
bal() { cast call $WMON "balanceOf(address)(uint256)" "$1" --rpc-url $RPC | num; }
B0=$(bal $BOB); A0=$(bal $ALICE)
cast send $VAULT "payout(address[])" "[$BOB,$ALICE]" --rpc-url $RPC --private-key "$KEEPER_KEY" >/dev/null
expect_eq "Bob was paid 1 MON less the 25 bps exercise fee" "$(( $(bal $BOB) - B0 ))" "997500000000000000"
expect_eq "Alice was paid her 4 MON residual" "$(( $(bal $ALICE) - A0 ))" "4000000000000000000"
expect_eq "the keeper received nothing" "$(bal $KEEPER)" "0"
expect_eq "no collateral left locked" "$(cast call $VAULT 'collateralLocked()(uint256)' --rpc-url $RPC | num)" "0"
expect_eq "the vault holds exactly the fees" "$(bal $VAULT)" "7500000000000000"

echo "== 11. fees =="
expect_revert "a keeper cannot sweep fees" "Unauthorized" cast send $VAULT "sweepFees()" --rpc-url $RPC --private-key "$KEEPER_KEY"
expect_revert "the pauser cannot sweep fees" "Unauthorized" cast send $VAULT "sweepFees()" --rpc-url $RPC --private-key "$PAUSER_KEY"
cast send $VAULT "sweepFees()" --rpc-url $RPC --private-key "$MULTISIG_KEY" >/dev/null
expect_eq "the treasury received the fees" "$(bal $TREASURY)" "7500000000000000"
expect_eq "the vault is empty" "$(bal $VAULT)" "0"

echo
echo "REHEARSAL PASSED"
