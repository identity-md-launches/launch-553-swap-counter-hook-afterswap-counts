// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookAddressMiner} from "../src/HookAddressMiner.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";
import {SwapCounterToken} from "../src/SwapCounterToken.sol";

/// @title Deploy
/// @notice Deploys `SwapCounterToken` and `SwapCounterHook` (at a mined CREATE2 address).
/// @dev `run()` is the only function that reads the environment:
///   - `EXPECTED_CHAIN_ID` (required): the chain the operator intends to deploy to. Must be
///     31337 or 11155111, or 0 for a local dry run on chain id 31337. Anything else reverts before
///     any transaction is built, so a wallet pointed at the wrong RPC cannot deploy.
///   - `POOL_MANAGER` (optional): the chain's Uniswap v4 PoolManager. Required on a real chain.
///     When unset on 31337 the script deploys a throwaway PoolManager so an offline dry run works.
/// No key is read here: the operator supplies the signer on the `forge script` command line, and
/// the IMD launch factory, which deploys for a launch, mines its own salt and calls the
/// constructors itself.
contract Deploy is Script {
    /// @notice Foundry's deterministic CREATE2 deployer, the contract `new X{salt: s}()` goes
    /// through inside a broadcast.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant TARGET_CHAIN_ID = 11155111; // Sepolia

    /// @notice The permission bits the hook address must carry.
    uint160 public constant HOOK_FLAGS = HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP;

    struct Deployment {
        SwapCounterToken token;
        SwapCounterHook hook;
        bytes32 hookSalt;
    }

    error UnexpectedChain(uint256 expected, uint256 actual);
    error ChainNotAllowed(uint256 chainId);
    error PoolManagerRequired(uint256 chainId);
    error HookAddressMismatch(address predicted, address deployed);

    /// @notice True when `expected` (from the environment) permits deploying on `actual`.
    function chainAllowed(uint256 expected, uint256 actual) public pure returns (bool) {
        if (expected == 0) return actual == LOCAL_CHAIN_ID;
        if (expected != actual) return false;
        return actual == LOCAL_CHAIN_ID || actual == TARGET_CHAIN_ID;
    }

    function run() external returns (Deployment memory d) {
        uint256 expected = vm.envUint("EXPECTED_CHAIN_ID");
        if (!chainAllowed(expected, block.chainid)) {
            if (expected != 0 && expected != block.chainid) revert UnexpectedChain(expected, block.chainid);
            revert ChainNotAllowed(block.chainid);
        }

        address poolManager = vm.envOr("POOL_MANAGER", address(0));

        vm.startBroadcast();
        if (poolManager == address(0)) {
            if (block.chainid != LOCAL_CHAIN_ID) revert PoolManagerRequired(block.chainid);
            poolManager = address(new PoolManager(address(0)));
            console2.log("local dry run: deployed a throwaway PoolManager at", poolManager);
        }
        d = deploy(IPoolManager(poolManager), CREATE2_DEPLOYER);
        vm.stopBroadcast();

        console2.log("SwapCounterToken:", address(d.token));
        console2.log("SwapCounterHook: ", address(d.hook));
        console2.log("hook salt:");
        console2.logBytes32(d.hookSalt);
    }

    /// @notice Deploys the token and the hook. Tests call this directly with their own manager.
    /// @param poolManager The chain's PoolManager; the hook's single constructor argument.
    /// @param create2Deployer The address whose CREATE2 the salt is mined for: the deterministic
    /// deployer inside a broadcast, this contract when called directly from a test.
    function deploy(IPoolManager poolManager, address create2Deployer) public returns (Deployment memory d) {
        d.token = new SwapCounterToken();

        bytes memory initCode = abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(poolManager));
        (address predicted, bytes32 salt) = HookAddressMiner.find(create2Deployer, HOOK_FLAGS, initCode);

        d.hook = new SwapCounterHook{salt: salt}(poolManager);
        d.hookSalt = salt;
        if (address(d.hook) != predicted) revert HookAddressMismatch(predicted, address(d.hook));
    }
}
