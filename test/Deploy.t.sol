// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookAddressMiner} from "../src/HookAddressMiner.sol";
import {SwapCounterHook} from "../src/SwapCounterHook.sol";

/// @dev Calls the script's `deploy` function directly, never `run()`, so nothing here reads the
/// environment.
contract DeployTest is Test {
    PoolManager manager;
    Deploy script;

    function setUp() public {
        manager = new PoolManager(address(this));
        script = new Deploy();
    }

    function test_deployProducesAValidHookAndTheFixedSupplyToken() public {
        Deploy.Deployment memory d = script.deploy(manager, address(script));

        assertEq(address(d.hook.poolManager()), address(manager));
        assertEq(HookFlags.flagsOf(address(d.hook)), script.HOOK_FLAGS());
        assertEq(script.HOOK_FLAGS(), HookFlags.AFTER_INITIALIZE | HookFlags.AFTER_SWAP);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(d.hook)), 3_000));
        assertEq(d.hook.totalSwaps(), 0);

        // The token mints to whoever runs the constructor: the script contract here, the
        // broadcaster in a real run, the factory in a launch.
        assertEq(d.token.totalSupply(), 1e27);
        assertEq(d.token.balanceOf(address(script)), 1e27);
        assertEq(d.token.decimals(), 18);
    }

    function test_deployedSaltReproducesTheAddress() public {
        Deploy.Deployment memory d = script.deploy(manager, address(script));
        bytes memory initCode = abi.encodePacked(type(SwapCounterHook).creationCode, abi.encode(manager));
        address recomputed = HookAddressMiner.computeAddress(address(script), d.hookSalt, keccak256(initCode));
        assertEq(recomputed, address(d.hook));
    }

    function test_deployedHookAcceptsPoolInitialization() public {
        Deploy.Deployment memory d = script.deploy(manager, address(script));
        address other = makeAddr("other-token");
        (Currency c0, Currency c1) = address(d.token) < other
            ? (Currency.wrap(address(d.token)), Currency.wrap(other))
            : (Currency.wrap(other), Currency.wrap(address(d.token)));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3_000, tickSpacing: 60, hooks: IHooks(address(d.hook))});
        manager.initialize(key, 79228162514264337593543950336);
    }

    function test_deployRevertsWhenMinedForAnotherDeployer() public {
        // The salt is mined for `create2Deployer`, so deploying from a different address lands on
        // an address whose bits do not match and the hook constructor refuses it.
        vm.expectRevert();
        script.deploy(manager, makeAddr("someone-else"));
    }

    function test_chainGuard() public view {
        assertTrue(script.chainAllowed(0, 31337), "0 allows a local dry run");
        assertTrue(script.chainAllowed(31337, 31337));
        assertTrue(script.chainAllowed(11155111, 11155111));
        assertFalse(script.chainAllowed(0, 11155111), "0 never allows a real chain");
        assertFalse(script.chainAllowed(11155111, 31337), "expected and actual must agree");
        assertFalse(script.chainAllowed(31337, 11155111));
        assertFalse(script.chainAllowed(1, 1), "mainnet is not a target of this script");
        assertFalse(script.chainAllowed(8453, 8453));
    }

    function testFuzz_chainGuardOnlyAcceptsTheTwoChains(uint256 expected, uint256 actual) public view {
        bool allowed = script.chainAllowed(expected, actual);
        if (allowed) {
            assertTrue(actual == 31337 || actual == 11155111);
            assertTrue(expected == actual || (expected == 0 && actual == 31337));
        }
    }
}
