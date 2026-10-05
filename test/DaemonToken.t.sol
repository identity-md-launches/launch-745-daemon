// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DaemonToken} from "../src/DaemonToken.sol";
import {DeployDaemonToken} from "../script/DeployDaemonToken.s.sol";

/// @notice A deployer that is a contract, so the test can show the supply goes to `msg.sender`
///         regardless of whether the sender is an EOA or a factory-like contract.
contract FactoryLike {
    function deployViaCreate2(bytes32 salt) external returns (address deployed) {
        bytes memory code = type(DaemonToken).creationCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "create2 failed");
    }

    function move(DaemonToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract DaemonTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

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
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Daemon");
        assertEq(token.symbol(), "DAEMON");
        assertEq(uint256(token.decimals()), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new DaemonToken();
    }

    /// @dev The launch factory deploys with CREATE2 and must be `msg.sender` for the mint.
    function test_create2DeploymentMintsToTheDeployingContract() public {
        FactoryLike factory = new FactoryLike();
        DaemonToken deployed = DaemonToken(factory.deployViaCreate2(bytes32(uint256(7))));
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
        // And the factory can forward it whole.
        assertTrue(factory.move(deployed, ALICE, SUPPLY / 10));
        assertEq(deployed.balanceOf(ALICE), SUPPLY / 10);
    }

    function test_deployScriptMintsToCaller() public {
        DeployDaemonToken script = new DeployDaemonToken();
        DaemonToken deployed = script.deploy();
        // `deploy()` creates the token from the script contract, so the script holds the supply.
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    function test_freshAccountsHoldNothing() public view {
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(ALICE, BOB), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // transfer: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456_789 * 10 ** 18 + 1;
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        token.transfer(ALICE, 100);
        vm.prank(ALICE);
        assertTrue(token.transfer(ALICE, 100));
        assertEq(token.balanceOf(ALICE), 100);
    }

    function test_chainedTransfersArriveWhole() public {
        token.transfer(ALICE, 1000);
        vm.prank(ALICE);
        token.transfer(BOB, 1000);
        vm.prank(BOB);
        token.transfer(CAROL, 1000);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(CAROL), 1000);
    }

    // ---------------------------------------------------------------------------------------------
    // transfer: failure
    // ---------------------------------------------------------------------------------------------

    function test_RevertWhen_transferExceedsBalance() public {
        token.transfer(ALICE, 10);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, ALICE, 10, 11));
        token.transfer(BOB, 11);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, BOB, 0, 1));
        token.transfer(ALICE, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_RevertWhen_transferMoreThanSupply() public {
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1));
        token.transfer(ALICE, SUPPLY + 1);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / allowance / transferFrom: success
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, BOB, 500);
        assertTrue(token.approve(BOB, 500));
        assertEq(token.allowance(deployer, BOB), 500);
    }

    function test_approveOverwritesPreviousAllowance() public {
        token.approve(BOB, 500);
        token.approve(BOB, 7);
        assertEq(token.allowance(deployer, BOB), 7);
        token.approve(BOB, 0);
        assertEq(token.allowance(deployer, BOB), 0);
    }

    function test_transferFromSpendsAllowance() public {
        token.transfer(ALICE, 1000);
        vm.prank(ALICE);
        token.approve(BOB, 600);

        vm.prank(BOB);
        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, CAROL, 400);
        assertTrue(token.transferFrom(ALICE, CAROL, 400));

        assertEq(token.balanceOf(ALICE), 600);
        assertEq(token.balanceOf(CAROL), 400);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(ALICE, BOB), 200);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        token.transfer(ALICE, 1000);
        vm.prank(ALICE);
        token.approve(BOB, 1000);
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 1000);
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.balanceOf(BOB), 1000);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.transfer(ALICE, 1000);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 999);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
        assertEq(token.balanceOf(CAROL), 999);
    }

    function test_transferFromSelfWithAllowance() public {
        token.approve(deployer, 5);
        assertTrue(token.transferFrom(deployer, ALICE, 5));
        assertEq(token.balanceOf(ALICE), 5);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom: failure
    // ---------------------------------------------------------------------------------------------

    function test_RevertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        token.transfer(ALICE, 1000);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        token.transfer(ALICE, 1000);
        vm.prank(ALICE);
        token.approve(BOB, 100);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientAllowance.selector, BOB, 100, 101));
        token.transferFrom(ALICE, CAROL, 101);
    }

    function test_RevertWhen_transferFromExceedsBalanceDespiteAllowance() public {
        token.transfer(ALICE, 50);
        vm.prank(ALICE);
        token.approve(BOB, 100);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, ALICE, 50, 100));
        token.transferFrom(ALICE, CAROL, 100);
        // Allowance is untouched when the transfer reverts.
        assertEq(token.allowance(ALICE, BOB), 100);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        token.approve(BOB, 100);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1);
    }

    function test_RevertWhen_transferFromZeroAddressSender() public {
        // Nobody can approve on behalf of address(0), so the allowance check fails first.
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(address(0), BOB, 1);
    }

    function test_allowanceDoesNotLetSpenderMoveOtherOwnersFunds() public {
        token.transfer(ALICE, 100);
        token.transfer(CAROL, 100);
        vm.prank(ALICE);
        token.approve(BOB, 100);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(CAROL, BOB, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No owner powers, no minting, no transfer rules
    // ---------------------------------------------------------------------------------------------

    /// @dev Mirrors the launch floor: none of the usual admin selectors exist, whether called by a
    ///      stranger or by the deployer, and none of them changes supply or conjures a balance.
    function test_noAdminSelectorIncreasesSupply() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
        }
    }

    /// @dev Mirrors the launch floor: no privileged selector moves or freezes a holder, and the
    ///      holder can still transfer afterwards.
    function test_noPrivilegedSelectorMovesOrFreezesAHolder() public {
        address holder = address(0x401D);
        token.transfer(holder, SUPPLY / 1000);
        uint256 held = token.balanceOf(holder);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], holder, true);
            vm.prank(deployer);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        vm.prank(deployer);
        (bool moved,) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, holder, deployer, 1));
        assertFalse(moved, "deployer moved a holder's balance without allowance");
        assertEq(token.balanceOf(holder), held);
        vm.prank(holder);
        assertTrue(token.transfer(BOB, held / 2));
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_noOwnerAccessor() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
    }

    function test_RevertWhen_sendingEther() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    /// @dev Same opcode scan the launch floor runs: no DELEGATECALL, CALLCODE or SELFDESTRUCT.
    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupplyAndIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        if (held > 0) token.transfer(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, ALICE, held, amount));
        token.transfer(BOB, amount);
    }

    function testFuzz_transferFromAccounting(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        allowed = bound(allowed, 0, type(uint256).max - 1); // keep below the "infinite" sentinel
        amount = bound(amount, 0, SUPPLY);
        if (held > 0) token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.approve(BOB, allowed);

        vm.prank(BOB);
        if (amount > allowed) {
            vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientAllowance.selector, BOB, allowed, amount));
            token.transferFrom(ALICE, CAROL, amount);
        } else if (amount > held) {
            vm.expectRevert(abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, ALICE, held, amount));
            token.transferFrom(ALICE, CAROL, amount);
        } else {
            assertTrue(token.transferFrom(ALICE, CAROL, amount));
            assertEq(token.balanceOf(CAROL), amount);
            assertEq(token.balanceOf(ALICE), held - amount);
            assertEq(token.allowance(ALICE, BOB), allowed - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approveIsExact(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(deployer, spender), amount);
    }
}
