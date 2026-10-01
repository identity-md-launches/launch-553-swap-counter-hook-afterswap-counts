// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SwapCounterToken} from "../src/SwapCounterToken.sol";

contract SwapCounterTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;

    SwapCounterToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new SwapCounterToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Swap Counter");
        assertEq(token.symbol(), "SWPC");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeFixedSupplyToTheDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), 1e27);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferMovesExactlyTheAmount() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferMoreThanBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferFromRespectsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 500e18);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 300e18));
        assertEq(token.balanceOf(bob), 300e18);
        assertEq(token.allowance(deployer, alice), 200e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 200e18, 201e18));
        token.transferFrom(deployer, bob, 201e18);
    }

    function test_hasNoMintOrAdminEntryPoints() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(address,uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], deployer, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer) + token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
