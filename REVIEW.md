# Review: SwapCounterHook and SwapCounterToken

Scope: `src/SwapCounterHook.sol`, `src/SwapCounterToken.sol`, `src/HookFlags.sol`,
`src/HookAddressMiner.sol`, `script/Deploy.s.sol`, the tests, and the vendored libraries. The
review was done by the same worker that wrote the code, against the `uniswap-v4-security`
checklist and the pinned `eth-security` pre-deploy checklist, and against the two pinned IMD floor
suites. It is a self-review, not an independent audit; the network's adversarial-review step is
still required before release.

## What was re-run

| Check                                                                      | Result                               |
| -------------------------------------------------------------------------- | ------------------------------------ |
| `forge build --offline` (solc 0.8.26, optimizer 200 runs, cancun)          | success, 85 files                    |
| `forge test --offline`                                                     | 40 passed, 0 failed (8 fuzz, 256 runs) |
| `forge fmt --check`                                                        | clean                                |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline`    | success, hook landed on a `0x…5040` address, salt `0x43f7` |
| `Hook.protected.t.sol` (pinned IMD floor) with `IMD_HOOK_FLAGS=4160`       | 3/3 passed                           |
| `Token.protected.t.sol` (pinned IMD floor) with `IMD_TOKEN_DECIMALS=18`    | 6/6 passed                           |
| Runtime bytecode scan for `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`         | none (floor test + manual)           |
| Slither / Mythril                                                          | not available in this environment; not run |

The floor suites were run from `test/scratch/` with their relative imports adjusted by one
directory level. The hook's creation code was given a fixed PoolManager constructor argument; the
hook's constructor never calls the manager, so the floor's `vm.etch` path is exercised without a
real manager.

## Findings

### F-1 (informational, accepted): per-sender counts are per router, not per user

`afterSwap`'s `sender` is the address that called `PoolManager.swap`. For almost every real swap
that is a router shared by many users, so `swapsBySender` measures routers. The brief asks for
counts "per sender address"; v4 defines that address as the router, and inventing per-user
identity from `hookData` would require trusting a router list that the brief does not provide.
Disposition: implemented as specified, documented prominently in the README and the contract's
NatSpec, and tested (`test_swapThroughThePoolCountsTheRouterAsSender`).

### F-2 (informational, accepted): any pool may use the hook, and counters are global

Nothing restricts which pools initialize with this hook. Anyone can create a pool with it and
inflate `totalSwaps` and their own router's count by swapping against their own liquidity. The
counters are informational, there is no value attached to them on chain, and the event carries the
`PoolId` so a consumer can filter. Disposition: accepted; documented as an assumption. An
allowlist would add an owner, which the brief does not ask for.

### F-3 (low, accepted): first swap by a new sender costs about 74k gas in the hook

Two storage slots go from zero to non-zero (the sender's counter and, on the very first swap ever,
`totalSwaps`), plus the event. This is above the security reference's 30k target for `afterSwap`
but under its 100k hard ceiling, and it is inherent to a persistent per-sender counter. Warm swaps
cost about 25k. Disposition: accepted; figures recorded in the README, not asserted in tests.

### F-4 (resolved during development): `getSlot0` is bound to `IPoolManager`, not `PoolManager`

A test called `manager.getSlot0` on the concrete `PoolManager`; `StateLibrary` is attached to
`IPoolManager`, so it did not compile. Fixed by casting in the test. No source impact.

No finding required a change to the delivered contracts.

## Checklist walk-through

### uniswap-v4-security

| #  | Check                                              | Status | Evidence                                                                                 |
| -- | -------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------- |
| 1  | callbacks verify `msg.sender == poolManager`       | yes    | `onlyPoolManager` on both enabled callbacks; fuzz test over callers; floor test          |
| 2  | router allowlisting if needed                      | n/a    | the hook gates nothing; see F-1                                                          |
| 3  | no unbounded loops                                 | yes    | no loops in the hook; `HookAddressMiner.find` is bounded at 200k and runs only at deploy |
| 4  | reentrancy guards on external calls                | n/a    | the hook makes no external calls                                                         |
| 5  | delta accounting sums to zero                      | yes    | the hook returns a zero delta and no `*ReturnDelta` permission; lifecycle tests compare deltas with a hook-less pool |
| 6  | fee-on-transfer tokens handled                     | n/a    | the hook never moves tokens                                                              |
| 7  | no hardcoded addresses                             | yes    | PoolManager is a constructor argument; the script's only literal is Foundry's CREATE2 deployer, used for salt prediction |
| 8  | slippage respected                                 | yes    | the hook does not touch swap parameters                                                  |
| 9  | no sensitive data on chain                         | yes    |                                                                                          |
| 10 | upgrade mechanisms secured                         | n/a    | none; no `DELEGATECALL` in runtime code                                                  |
| 11 | `beforeSwapReturnDelta` justified                  | n/a    | disabled                                                                                 |
| 12 | fuzz testing                                       | yes    | 8 fuzz tests                                                                             |
| 13 | invariant testing                                  | n/a    | no delta returns; counter-growth property covered by `testFuzz_counterGrowsByOnePerSwap` |

Risk score: permissions `afterInitialize` (LOW) + `afterSwap` (MEDIUM); no external calls; two
counters of state; no upgrade mechanism; no token handling. Low tier: self-audit plus peer review
is the reference's recommendation, and the network's adversarial review satisfies the peer step.

Absolute prohibitions: `msg.sender` is used only to identify the PoolManager, never a user; no
`tx.origin`; no `block.timestamp`; no ETH transfers; no hardcoded gas; no ignored return values.

### eth-security pre-deploy checklist

- **Access control**: no privileged functions exist. Callbacks are restricted to the PoolManager.
- **Pausable tradeoff**: no pause; nothing can freeze users.
- **Reentrancy**: no external calls from the hook. The token is OpenZeppelin ERC20 with no hooks.
- **Token decimals / integer math / oracle / infinite approvals / fee-on-transfer / MEV**: the
  hook performs no arithmetic on amounts, holds no tokens and reads no prices. Test approvals of
  `type(uint256).max` are to test routers only.
- **Return values checked**: the hook calls nothing. The script checks the deployed address
  against the prediction and reverts on mismatch.
- **Input validation**: constructor rejects a zero PoolManager and a wrong address. Callback
  arguments are copied into the event, not interpreted, so no bounds apply.
- **Events**: every state change (each swap) emits `SwapCounted`. `afterInitialize` changes no
  state and emits nothing.
- **Proxy / storage layout / upgrade authority / EIP-712 / delegatecall**: none used.
- **Automated analysis**: Foundry fuzzing run. Slither and Mythril are not installed here and
  were not run; this is an open item for the adversarial reviewer if their environment has them.
- **Tested edge cases**: zero PoolManager, wrong address, unauthorized callers (fuzzed), disabled
  callbacks, exact-in and exact-out in both directions, fuzzed amounts to 10,000 tokens, many
  swaps, two routers, two pools, a hook-less control pool.
- **Source verified on block explorer**: the deployer's step after deployment; not done here.

### IMD launch rules

- Initialization callback enabled (`afterInitialize`), caller-checked, returns its selector.
- PoolManager is a constructor argument; `launch.json` should carry `"$poolManager"`.
- Token: no constructor arguments, 18 decimals, exactly 10^27 minted to `msg.sender`, no admin
  functions, OpenZeppelin ERC20 only. Floor suite 6/6.
- `foundry.toml`: `solc = "0.8.26"`, `ffi = false`, `fs_permissions = []`, no `offline` key, no
  compiler path. All dependencies committed under `lib/`; no submodules.
- Tests read no environment variables; the script's `run()` is the only reader and tests call
  `deploy()` and `chainAllowed()` directly.

## Open items for the next step

1. Independent adversarial review by another contributor.
2. Static analysis (Slither) in an environment that has it.
3. After deployment: explorer verification, confirmation of the PoolManager address on the target
   chain, and recording the mined salt and hook address in the manifest.
