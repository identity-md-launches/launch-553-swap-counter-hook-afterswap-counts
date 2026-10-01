// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {SwapCounterToken} from "src/SwapCounterToken.sol";

/// @dev All successful transfers stay within this closed actor set. Ghost balances start from
/// a known allocation and change only by the amounts actors authorize, never by reading balances.
contract SwapCounterTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    SwapCounterToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(SwapCounterToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            expectedBalance[actors[i]] = SUPPLY / actors.length;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool unlimited) external {
        // Approval has no supply cap: cover finite values above the entire token supply too.
        uint256 amount = unlimited ? type(uint256).max : amountSeed;
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < allowance ? expectedBalance[owner] : allowance;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _move(owner, to, amount);
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] = allowance - amount;
    }

    function rejectedTransfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool zeroRecipient) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance[from];
        if (zeroRecipient) {
            uint256 amount = bound(amountSeed, 0, balance);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(from);
            token.transfer(address(0), amount);
        } else {
            uint256 amount = balance + bound(amountSeed, 1, type(uint256).max - balance);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
            );
            vm.prank(from);
            token.transfer(_actor(toSeed), amount);
        }
        // No ghost update: invariants must observe the entire ledger unchanged after rejection.
    }

    function rejectedTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint8 failureSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 mode = failureSeed % 3;
        if (mode == 0) {
            // A revoked spender cannot move even one wei, including a self-transfer.
            _approve(owner, spender, 0);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
            vm.prank(spender);
            token.transferFrom(owner, to, 1);
        } else if (mode == 1) {
            // Allowance passes first; the later balance check must roll its consumption back.
            uint256 balance = expectedBalance[owner];
            uint256 amount = balance + 1;
            _approve(owner, spender, amount);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
            );
            vm.prank(spender);
            token.transferFrom(owner, to, amount);
        } else {
            // Test rollback of a finite approval even if the account has an empty balance.
            uint256 amount = expectedBalance[owner];
            _approve(owner, spender, amount);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(owner, address(0), amount);
        }
    }

    function rejectedApproval(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        assertEq(token.allowance(owner, address(0)), 0);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _move(address from, address to, uint256 amount) internal {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }
}

/// @dev The token maintains balances, so check conservation after random sequences of both
/// successful and rejected calls. Unexpected handler reverts are failures, not discarded steps.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwapCounterTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    SwapCounterToken internal token;
    SwapCounterTokenHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        actors = [makeAddr("tokenActor0"), makeAddr("tokenActor1"), makeAddr("tokenActor2"), makeAddr("tokenActor3")];
        vm.prank(actors[0]);
        token = new SwapCounterToken();
        for (uint256 i = 1; i < actors.length; ++i) {
            vm.prank(actors[0]);
            assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
        }
        handler = new SwapCounterTokenHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectedTransfer.selector;
        selectors[4] = handler.rejectedTransferFrom.selector;
        selectors[5] = handler.rejectedApproval.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyEqualsAllActorBalances() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "tokens disappeared or were created");
        assertEq(token.totalSupply(), SUPPLY, "fixed supply changed");
        assertEq(token.balanceOf(address(0)), 0, "tokens reached the zero address");
    }

    function invariant_balancesAndAllowancesMatchAuthorizedOperations() public view {
        for (uint256 i; i < actors.length; ++i) {
            address owner = actors[i];
            assertEq(token.balanceOf(owner), handler.expectedBalance(owner), "unexpected debit or credit");
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(owner, actors[j]),
                    handler.expectedAllowance(owner, actors[j]),
                    "approval leaked, failed call consumed allowance, or spend was not charged"
                );
            }
        }
    }

    function test_zeroOneAndFullBalanceTransfersExerciseTheModel() public {
        handler.transfer(0, 1, 0);
        handler.transfer(0, 1, 1);
        uint256 remaining = SUPPLY / 4 - 1;
        handler.transfer(0, 2, remaining);
        assertEq(token.balanceOf(actors[0]), 0);
        assertEq(token.balanceOf(actors[1]), SUPPLY / 4 + 1);
        assertEq(token.balanceOf(actors[2]), SUPPLY / 2 - 1);
        invariant_fixedSupplyEqualsAllActorBalances();
        invariant_balancesAndAllowancesMatchAuthorizedOperations();
    }

    function test_selfTransferConsumesFiniteAllowanceWithoutChangingBalance() public {
        handler.approve(0, 1, 2, false);
        handler.transferFrom(0, 1, 0, 1);
        assertEq(token.balanceOf(actors[0]), SUPPLY / 4);
        assertEq(token.allowance(actors[0], actors[1]), 1);
        handler.transfer(0, 0, SUPPLY / 4);
        invariant_fixedSupplyEqualsAllActorBalances();
        invariant_balancesAndAllowancesMatchAuthorizedOperations();
    }

    function test_fullSupplyCanMoveWithoutFeeOrRounding() public {
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(i, 0, SUPPLY / 4);
        }
        assertEq(token.balanceOf(actors[0]), SUPPLY);
        handler.transfer(0, 1, SUPPLY);
        assertEq(token.balanceOf(actors[0]), 0);
        assertEq(token.balanceOf(actors[1]), SUPPLY);
        invariant_fixedSupplyEqualsAllActorBalances();
        invariant_balancesAndAllowancesMatchAuthorizedOperations();
    }

    function test_maximumFiniteApprovalIsConsumedAndCanBeReplaced() public {
        handler.approve(0, 1, type(uint256).max - 1, false);
        handler.transferFrom(0, 1, 2, 1);
        assertEq(token.allowance(actors[0], actors[1]), type(uint256).max - 2);
        handler.approve(0, 1, 1, false);
        handler.transferFrom(0, 1, 2, 1);
        assertEq(token.allowance(actors[0], actors[1]), 0);
        invariant_fixedSupplyEqualsAllActorBalances();
        invariant_balancesAndAllowancesMatchAuthorizedOperations();
    }

    function test_infiniteApprovalSurvivesRepeatedSpendingThenCanBeRevoked() public {
        handler.approve(0, 1, 0, true);
        handler.transferFrom(0, 1, 2, 1);
        handler.transferFrom(0, 1, 3, SUPPLY / 4 - 1);
        assertEq(token.allowance(actors[0], actors[1]), type(uint256).max);
        handler.rejectedTransferFrom(0, 1, 2, 0);
        assertEq(token.allowance(actors[0], actors[1]), 0);
        invariant_fixedSupplyEqualsAllActorBalances();
        invariant_balancesAndAllowancesMatchAuthorizedOperations();
    }

    function test_failedTransfersPreserveFiniteAllowancesAndBalances() public {
        handler.rejectedTransferFrom(0, 1, 2, 1);
        assertEq(token.allowance(actors[0], actors[1]), SUPPLY / 4 + 1);
        handler.rejectedTransferFrom(0, 1, 2, 2);
        assertEq(token.allowance(actors[0], actors[1]), SUPPLY / 4);
        handler.rejectedTransfer(0, 1, type(uint256).max, false);
        handler.rejectedTransfer(0, 1, 0, true);
        handler.rejectedApproval(0, type(uint256).max);
        invariant_fixedSupplyEqualsAllActorBalances();
        invariant_balancesAndAllowancesMatchAuthorizedOperations();
    }
}
