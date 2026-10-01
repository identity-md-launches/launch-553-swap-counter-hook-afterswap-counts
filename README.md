# SwapCounterHook

A Uniswap v4 hook that counts swaps. On every swap through a pool that uses it, `afterSwap`
increments a counter for the swap's `sender`, increments a global counter, and emits one
`SwapCounted` event. It never changes amounts, never returns a delta, never overrides a fee,
never holds tokens and has no owner or admin function.

The launch token `SwapCounterToken` (`Swap Counter`, `SWPC`) is deployed beside it: a plain
fixed-supply ERC-20.

| Contract                                      | Purpose                                            |
| --------------------------------------------- | -------------------------------------------------- |
| `src/SwapCounterHook.sol`                     | The hook: `afterInitialize` + `afterSwap` counters |
| `src/SwapCounterToken.sol`                    | Launch token, 1,000,000,000 × 10^18, no admin      |
| `src/HookFlags.sol`                           | The 14 permission bits and address helpers         |
| `src/HookAddressMiner.sol`                    | CREATE2 salt mining for the hook address           |
| `script/Deploy.s.sol`                         | Reviewable deploy script (token + mined hook)      |
| `docs/abi/SwapCounterHook.json`, `...Token.json` | ABI exports                                     |

## Rules of the hook

- **Counts, nothing else.** `afterSwap` does `swapsBySender[sender]++`, `totalSwaps++`, emits
  `SwapCounted`, and returns `(afterSwap.selector, 0)`. The `afterSwapReturnDelta` permission is
  off, so the PoolManager would ignore any non-zero delta anyway; the tests assert it is zero.
- **`sender` is the router.** Uniswap v4 passes the address that called `PoolManager.swap`, which
  is the router or the contract that unlocked the manager, not the end user behind it. The
  per-sender counter therefore counts per router. If a project needs per-user counts, a trusted
  router has to pass the user in `hookData` and the hook must be changed to trust that router; this
  version deliberately does not decode `hookData`.
- **Counts are global across pools.** One deployed hook can serve any number of pools; both
  counters aggregate over all of them. The `SwapCounted` event carries the `PoolId`, so per-pool
  counts can be derived off chain from the log.
- **`afterInitialize` accepts any pool.** It is enabled only because an IMD launch requires an
  initialization callback (the factory deploys the hook and initializes its pool in one
  transaction, so nobody can initialize the predicted pool while the hook has no code). It checks
  its caller and returns its selector; it does not restrict fee, tick spacing or currencies.
- **Only the PoolManager may call a callback.** `afterInitialize` and `afterSwap` revert with
  `NotPoolManager()` for any other caller. The twelve disabled callbacks revert with
  `HookNotImplemented()` for everyone.
- **The address encodes the permissions.** The constructor runs
  `Hooks.validateHookPermissions` and reverts with `HookAddressNotValid` unless the deployed
  address carries exactly `AFTER_INITIALIZE | AFTER_SWAP` (`0x1040`, decimal 4160) in its low 14
  bits. The deployer must mine a CREATE2 salt; `HookAddressMiner.find` does this on chain and the
  script and tests use it.
- **No owner, no upgrade, no pause, no escape hatch.** The runtime code contains no
  `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`. Nothing can be changed after deployment.

## Interface

```solidity
// views
function poolManager() external view returns (IPoolManager);
function totalSwaps() external view returns (uint256);
function swapsBySender(address sender) external view returns (uint256);
function swapCount(address sender) external view returns (uint256); // same as swapsBySender
function getHookPermissions() external pure returns (Hooks.Permissions memory);

// event, one per swap
event SwapCounted(
    PoolId indexed poolId,
    address indexed sender,     // the router that called PoolManager.swap
    uint256 senderSwapCount,    // sender's count after this swap
    uint256 totalSwapCount,     // global count after this swap
    bool zeroForOne,
    int256 amountSpecified,
    BalanceDelta delta          // the swapper's delta as the pool computed it; reported, not changed
);

// errors
error NotPoolManager();
error HookNotImplemented();
error ZeroPoolManager();
```

The token is OpenZeppelin `ERC20` with a constant `TOTAL_SUPPLY()` of `1e27`, 18 decimals, and no
other function. Nothing in the brief asked the token for anything beyond the standard shape, so
nothing was left out.

## Hook configuration record

The configuration in the OpenZeppelin Contracts Wizard's canonical shape, implemented by hand on
v4-core's `IHooks` (this repository vendors no `uniswap-hooks` or v4-periphery `BaseHook`; the
hook is small enough that a base contract would add more code than it removes):

```json
{
  "hook": "BaseHook",
  "name": "SwapCounterHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": false,
    "afterInitialize": true,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": false,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": false,
    "afterSwapReturnDelta": false,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none",
  "info": { "license": "MIT" }
}
```

`access` is recorded as `none` rather than one of the Wizard's three options: the brief asks for
an observer with no administrative behaviour, so there is nothing for an owner to do and the
constructor takes only the PoolManager.

Key sections of the source:

- **constructor** stores the PoolManager (rejecting the zero address) and validates the address
  bits against `getHookPermissions()`.
- **`getHookPermissions`** declares `afterInitialize` and `afterSwap` only.
- **`afterInitialize`** is `onlyPoolManager`, changes nothing, returns its selector.
- **`afterSwap`** is `onlyPoolManager`, increments both counters, emits `SwapCounted`, returns a
  zero delta.

## Assumptions

- The PoolManager at the constructor argument is the canonical Uniswap v4 PoolManager of the
  target chain. The hook trusts it completely: whatever it reports as `sender` is counted.
- The hook does not need to know which pools use it. Any pool may be initialized with it, and any
  swap through such a pool is counted. If the launch wants only its own pool counted, that is an
  off-chain filter on `poolId` in the event, not an on-chain restriction.
- Counters are `uint256` and are never reset. Overflow is not reachable.
- The Cancun EVM is available on the target chain (the PoolManager itself needs transient storage).
  Sepolia (11155111) has it.
- The brief gave no token name or symbol; `Swap Counter` / `SWPC` were chosen as a short project
  name. The IMD launch factory supplies its own hook salt and PoolManager; `script/Deploy.s.sol`
  exists for a reviewable stand-alone deployment and for the tests, not for the factory.

## Deployment parameters

| Parameter          | Value                                                                                         |
| ------------------ | --------------------------------------------------------------------------------------------- |
| Hook constructor   | `(IPoolManager poolManager)` — in `launch.json` written as `"$poolManager"`, never a literal |
| Hook address flags | low 14 bits must equal `0x1040` (`AFTER_INITIALIZE \| AFTER_SWAP`, decimal 4160)             |
| Hook salt          | mined per deployer address and init code; `HookAddressMiner.find` or an off-chain miner       |
| Token constructor  | none; mints `1e27` to `msg.sender` (the factory or the broadcaster)                           |
| Token decimals     | 18                                                                                            |
| Compiler           | solc 0.8.26 (v4-core's pin), optimizer on, 200 runs, `evm_version = cancun`                   |
| Target chain       | Sepolia 11155111 (script also permits 31337 for local runs)                                   |

Gas per callback from the test run (not asserted, Foundry isolates calls so figures vary):

| Callback          | Typical | Max observed | Note                                                                 |
| ----------------- | ------- | ------------ | -------------------------------------------------------------------- |
| `afterInitialize` | ~0.8k   | ~0.8k        | caller check + return                                                |
| `afterSwap`       | ~25k    | ~74k         | max is the first swap ever by a new sender: two zero→non-zero SSTOREs |

Both sit under the security reference's 100k hard ceiling for `afterSwap`; the first-swap case
exceeds its 30k target because two counters go from zero, which is inherent to the brief.

## Building and testing offline

The verifier has no network. Every dependency is committed as ordinary files under `lib/`:

- `lib/forge-std` (1.16.2, `src/` only)
- `lib/v4-core` (Uniswap v4-core 1.0.2: `src/`, `test/utils/CurrencySettler.sol`, and
  `lib/solmate/src/auth/Owned.sol`; `src/test/ProxyPoolManager.sol` removed because it needs an
  OpenZeppelin proxy that is not vendored and nothing here uses it)
- `lib/openzeppelin-contracts` (5.7.0: `ERC20.sol`, `IERC20.sol`, `IERC20Metadata.sol`,
  `IERC6093.sol`, `Context.sol`)

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline   # local dry run, no RPC
```

`foundry.toml` sets `ffi = false`, `fs_permissions = []`, and pins `solc = "0.8.26"`. Tests read
no environment variables and do not depend on the calling address.

### Test coverage

`test/SwapCounterHook.t.sol` (27 tests, 6 fuzz):

- permissions, address bits, `HookFlags` mirrors v4-core bit for bit
- constructor failures: zero PoolManager, address without the flags
- every callback refuses non-PoolManager callers (fuzzed); disabled callbacks revert for everyone
- `afterSwap` counts per sender and in total and emits `SwapCounted` (direct and fuzzed)
- `afterSwap` always returns a zero delta (fuzzed over sender, direction, amount, delta)
- full lifecycle through a real `PoolManager`: initialize, add liquidity, swap exact-in and
  exact-out in both directions; every swap's `BalanceDelta` equals the same swap on an identical
  pool with no hook (fuzzed over amount, direction, exact-in/out), so the hook changes no amount
- the LP fee of the hooked pool equals the plain pool's; the hook holds no tokens and no claims
- two routers are counted separately; swaps on a hook-less pool and liquidity changes are not
  counted; two pools using the hook share the counters; a second pool initializes

`test/SwapCounterToken.t.sol` (7 tests, 1 fuzz): metadata, fixed supply to deployer, transfer,
insufficient balance, allowance, no mint/admin selectors, supply conservation.

`test/Deploy.t.sol` (6 tests, 1 fuzz): `deploy()` called directly with a test PoolManager yields a
valid hook and the supply; the salt reproduces the address; the deployed hook accepts pool
initialization; mining for the wrong deployer fails; the chain guard admits only 31337 and
11155111.

The pinned IMD floor suites (`Hook.protected.t.sol`, `Token.protected.t.sol`) were run locally
from `test/scratch` against this hook's creation code with `IMD_HOOK_FLAGS=4160`: 9/9 pass.

## Operator-only deployment

Deployment is done by the network's deployer after review. For a stand-alone deployment the
script needs two environment values and a signer supplied on the command line; it reads no key.

```sh
EXPECTED_CHAIN_ID=11155111 POOL_MANAGER=<sepolia PoolManager> \
  forge script script/Deploy.s.sol:Deploy --rpc-url <sepolia rpc> --broadcast <signer flags>
```

- `EXPECTED_CHAIN_ID` must equal the connected chain and be 31337 or 11155111; `0` is accepted
  only for a local 31337 dry run. Any other combination reverts before a transaction is built.
- `POOL_MANAGER` is required on a real chain. When unset on 31337 the script deploys a throwaway
  PoolManager so the offline dry run works. The address is never hardcoded.
- Inside the broadcast the hook is deployed with `new SwapCounterHook{salt: salt}(poolManager)`,
  which Foundry routes through the deterministic CREATE2 deployer
  `0x4e59b44847b379578588920cA78FbF26c0B4956C`; the salt is mined for that deployer, and the
  script reverts if the resulting address differs from the prediction.
- The IMD launch factory does not use this script: it deploys the token and the hook itself with
  the PoolManager from `"$poolManager"` and its own mined salt, then initializes the pool.

## Operational responsibilities

- **Nothing to operate.** There is no owner, keeper, parameter or upgrade. Once deployed, the hook
  cannot be changed, paused or drained.
- **Monitoring.** Index `SwapCounted` for analytics. The event's `delta` is the pool's own figure
  for the swapper; the hook reports it and does not modify it.
- **Reading counts.** `totalSwaps()` and `swapsBySender(router)` are free view calls.
- **Open items for the deployer** (not done here, no deployment in this task): explorer
  verification with `forge verify-contract`; confirming the PoolManager address against the chain
  (`cast code`); recording the mined salt and resulting hook address in the manifest.
- Tests passing do not constitute a security audit. `REVIEW.md` records the independent-style
  review done here; an adversarial review by another contributor is the network's step before
  release.
