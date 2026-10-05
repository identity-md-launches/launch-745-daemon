// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {DaemonToken} from "../src/DaemonToken.sol";

/// @title DaemonToken edge cases
/// @notice Inputs the base suite does not pin: the zero address as the *caller*, the boundary of the
///         unlimited-allowance sentinel, round-trips, idempotence, and the exact state left behind by
///         a reverted call. Fuzz runs are set inline because foundry.toml is not ours to change.
/// forge-config: default.fuzz.runs = 1000
contract DaemonTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 constant MAX = type(uint256).max;

    DaemonToken token;
    address deployer;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        deployer = address(this);
        token = new DaemonToken();
    }

    // ---------------------------------------------------------------------------------------------
    // The zero address as caller: the two revert paths the base suite cannot reach from a normal EOA
    // ---------------------------------------------------------------------------------------------

    function test_RevertWhen_zeroAddressTransfers() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidSender.selector, address(0)));
        token.transfer(ALICE, 0);
    }

    function test_RevertWhen_zeroAddressTransfersEvenToItself() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidSender.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_RevertWhen_zeroAddressApproves() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidApprover.selector, address(0)));
        token.approve(ALICE, 1);
    }

    function test_RevertWhen_zeroAddressApprovesZeroSpender() public {
        // Approver is checked before spender.
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidApprover.selector, address(0)));
        token.approve(address(0), 1);
    }

    /// @dev A zero-amount transferFrom passes the allowance check trivially (0 <= 0), so the zero
    ///      address as `from` is caught by the sender check instead. Pins the order of checks: the
    ///      zero address can never be a sender even when nothing would move.
    function test_RevertWhen_transferFromZeroAddressSenderWithZeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Zero-amount paths through every function
    // ---------------------------------------------------------------------------------------------

    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(BOB);
        assertTrue(token.transferFrom(deployer, CAROL, 0));
        assertEq(token.balanceOf(CAROL), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferFromZeroAmountToZeroAddressStillReverts() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 0);
    }

    function test_transferZeroAmountToZeroAddressStillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_approveZeroAmountToZeroSpenderStillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
    }

    function test_transferZeroEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        token.transfer(BOB, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // The unlimited-allowance sentinel boundary
    // ---------------------------------------------------------------------------------------------

    function test_allowanceOneBelowMaxIsDecremented() public {
        token.transfer(ALICE, 10);
        vm.prank(ALICE);
        token.approve(BOB, MAX - 1);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 3);
        assertEq(token.allowance(ALICE, BOB), MAX - 4);
    }

    function test_unlimitedAllowanceStillRequiresBalance() public {
        token.transfer(ALICE, 10);
        vm.prank(ALICE);
        token.approve(BOB, MAX);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, ALICE, 10, 11));
        token.transferFrom(ALICE, CAROL, 11);
        assertEq(token.allowance(ALICE, BOB), MAX);
        assertEq(token.balanceOf(ALICE), 10);
    }

    function test_unlimitedAllowanceSurvivesTransferFromOfZero() public {
        vm.prank(ALICE);
        token.approve(BOB, MAX);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 0);
        assertEq(token.allowance(ALICE, BOB), MAX);
    }

    function test_unlimitedAllowanceSurvivesManySpends() public {
        token.transfer(ALICE, 1000);
        vm.prank(ALICE);
        token.approve(BOB, MAX);
        for (uint256 i; i < 10; ++i) {
            vm.prank(BOB);
            token.transferFrom(ALICE, CAROL, 100);
        }
        assertEq(token.allowance(ALICE, BOB), MAX);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(CAROL), 1000);
    }

    function test_unlimitedAllowanceCanBeRevoked() public {
        vm.prank(ALICE);
        token.approve(BOB, MAX);
        vm.prank(ALICE);
        token.approve(BOB, 0);
        assertEq(token.allowance(ALICE, BOB), 0);
        token.transfer(ALICE, 1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
    }

    function test_transferFromDoesNotEmitApproval() public {
        token.approve(BOB, 10);
        vm.recordLogs();
        vm.prank(BOB);
        token.transferFrom(deployer, ALICE, 4);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "expected exactly one event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(token.allowance(deployer, BOB), 6);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance is per (owner, spender) and does not leak
    // ---------------------------------------------------------------------------------------------

    function test_allowanceIsNotSymmetric() public {
        vm.prank(ALICE);
        token.approve(BOB, 100);
        assertEq(token.allowance(ALICE, BOB), 100);
        assertEq(token.allowance(BOB, ALICE), 0);
    }

    function test_spenderCannotReuseAllowanceAfterOwnerDrains() public {
        token.transfer(ALICE, 100);
        vm.prank(ALICE);
        token.approve(BOB, 100);
        // Owner moves its own tokens out; the allowance stays but there is nothing to spend.
        vm.prank(ALICE);
        token.transfer(CAROL, 100);
        assertEq(token.allowance(ALICE, BOB), 100);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, ALICE, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_transferDoesNotTouchAllowances() public {
        token.approve(BOB, 55);
        token.transfer(ALICE, 10);
        assertEq(token.allowance(deployer, BOB), 55);
        assertEq(token.allowance(ALICE, BOB), 0);
    }

    function test_receiverGainsNoAllowanceFromTransfer() public {
        token.transfer(ALICE, 10);
        assertEq(token.allowance(deployer, ALICE), 0);
        assertEq(token.allowance(ALICE, deployer), 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(deployer, ALICE, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Round-trips and idempotence (fuzzed)
    // ---------------------------------------------------------------------------------------------

    /// @dev Sending an amount and sending it back restores both balances exactly.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// @dev Splitting a transfer into two parts arrives the same as sending it at once.
    function testFuzz_transferIsAdditive(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        token.transfer(ALICE, a);
        token.transfer(ALICE, b);
        assertEq(token.balanceOf(ALICE), a + b);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }

    /// @dev The order of two independent transfers does not matter.
    function testFuzz_transferOrderIsIrrelevant(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        DaemonToken other = new DaemonToken();

        token.transfer(ALICE, a);
        token.transfer(BOB, b);
        other.transfer(BOB, b);
        other.transfer(ALICE, a);

        assertEq(token.balanceOf(ALICE), other.balanceOf(ALICE));
        assertEq(token.balanceOf(BOB), other.balanceOf(BOB));
        assertEq(token.balanceOf(deployer), other.balanceOf(deployer));
    }

    /// @dev Approving the same value twice is a no-op the second time; approve is idempotent.
    function testFuzz_approveIsIdempotent(address spender, uint256 amount) public {
        spender = address(uint160(bound(uint256(uint160(spender)), 1, type(uint160).max)));
        token.approve(spender, amount);
        token.approve(spender, amount);
        assertEq(token.allowance(deployer, spender), amount);
    }

    /// @dev The last approve wins, whatever came before.
    function testFuzz_approveLastWriteWins(uint256 first, uint256 second) public {
        token.approve(BOB, first);
        token.approve(BOB, second);
        assertEq(token.allowance(deployer, BOB), second);
    }

    /// @dev A self-transfer of any amount within balance leaves the balance unchanged.
    function testFuzz_selfTransferIsNoOp(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), held);
    }

    /// @dev A self-transfer above balance still reverts: no special-casing of from == to.
    function testFuzz_selfTransferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, MAX);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, ALICE, held, amount));
        token.transfer(ALICE, amount);
    }

    /// @dev transferFrom where spender == owner == receiver behaves like a self-transfer that still
    ///      spends allowance.
    function testFuzz_transferFromSelfToSelfSpendsAllowance(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, MAX - 1);
        amount = bound(amount, 0, held < allowed ? held : allowed);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.approve(ALICE, allowed);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(ALICE, ALICE, amount));
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.allowance(ALICE, ALICE), allowed - amount);
    }

    // ---------------------------------------------------------------------------------------------
    // A reverted call leaves no trace
    // ---------------------------------------------------------------------------------------------

    function testFuzz_failedTransferChangesNothing(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, MAX);
        token.transfer(ALICE, held);
        token.approve(BOB, 7);

        vm.prank(ALICE);
        (bool ok,) = address(token).call(abi.encodeWithSelector(token.transfer.selector, BOB, amount));
        assertFalse(ok);

        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(deployer), SUPPLY - held);
        assertEq(token.allowance(deployer, BOB), 7);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_failedTransferFromChangesNothing(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, MAX - 1);
        // Pick an amount that fails at least one of the two checks.
        uint256 floor = (held < allowed ? held : allowed) + 1;
        amount = bound(amount, floor, MAX);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.approve(BOB, allowed);

        vm.prank(BOB);
        (bool ok,) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, ALICE, CAROL, amount));
        assertFalse(ok);

        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(CAROL), 0);
        assertEq(token.allowance(ALICE, BOB), allowed);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Many holders, exactness at scale
    // ---------------------------------------------------------------------------------------------

    /// @dev Distributing to many addresses and summing them up gives back exactly the supply: the
    ///      kind of flow a MerkleDistributor performs.
    function testFuzz_fanOutConservesSupply(uint8 holders, uint256 seed) public {
        uint256 n = bound(uint256(holders), 1, 64);
        uint256 remaining = SUPPLY;
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            address to = address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1));
            uint256 amount = uint256(keccak256(abi.encode(seed, i, "amt"))) % (remaining + 1);
            if (i == n - 1) amount = remaining;
            uint256 before = token.balanceOf(to);
            token.transfer(to, amount);
            assertEq(token.balanceOf(to), before + amount, "fan-out arrived short");
            remaining -= amount;
            sum += amount;
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Whoever deploys gets the supply, and a second deployment is independent of the first.
    function test_twoDeploymentsAreIndependent() public {
        DaemonToken second = new DaemonToken();
        assertEq(second.balanceOf(deployer), SUPPLY);
        token.transfer(ALICE, SUPPLY);
        assertEq(second.balanceOf(deployer), SUPPLY);
        assertEq(second.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(deployer), 0);
    }

    /// @dev A caller other than the deployer deploying gets the supply, not the test contract.
    function testFuzz_mintGoesToWhoeverDeploys(address who) public {
        who = address(uint160(bound(uint256(uint160(who)), 1, type(uint160).max)));
        vm.assume(who.code.length == 0 && who != address(vm) && who != 0x000000000000000000636F6e736F6c652e6c6f67);
        vm.prank(who);
        DaemonToken deployed = new DaemonToken();
        assertEq(deployed.balanceOf(who), SUPPLY);
        assertEq(deployed.balanceOf(deployer), 0);
    }
}
