// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DaemonToken} from "../src/DaemonToken.sol";

/// @title DaemonToken invariant handler
/// @notice Drives `DaemonToken` with random sequences of transfers, approvals and transferFroms
///         between a fixed set of actors, with bounded inputs, and keeps ghost ledgers of what the
///         token *should* hold. The handler never reverts: unclamped variants wrap the call in
///         try/catch and check that a revert is the one the pre-state predicts, and that a reverted
///         call changed nothing.
/// @dev The handler is the deployer, so it starts holding the whole supply and is also actor 0.
contract DaemonTokenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 10 ** 18;

    DaemonToken public immutable token;

    address[] public actors;
    mapping(address => bool) public isActor;

    // ---------------------------------------------------------------------------------------------
    // Ghost state
    // ---------------------------------------------------------------------------------------------

    /// @dev Amount each actor has received through successful calls (not counting the mint).
    mapping(address => uint256) public ghostReceived;
    /// @dev Amount each actor has sent through successful calls.
    mapping(address => uint256) public ghostSent;
    /// @dev The allowance the handler expects after the last successful approve / transferFrom.
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostMovedTotal;
    uint256 public ghostSuccessfulTransfers;
    uint256 public ghostSuccessfulTransferFroms;
    uint256 public ghostExpectedReverts;
    uint256 public ghostApprovals;
    uint256 public ghostProbes;

    // Call counters, exposed for the summary.
    mapping(bytes32 => uint256) public calls;

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    constructor() {
        token = new DaemonToken();

        actors.push(address(this));
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xDA7E));
        actors.push(address(0xE4E));
        for (uint256 i; i < actors.length; ++i) {
            isActor[actors[i]] = true;
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev What the ledger says `a` should hold: the mint (actor 0 only) plus received minus sent.
    function expectedBalance(address a) public view returns (uint256) {
        uint256 initial = a == address(this) ? SUPPLY : 0;
        return initial + ghostReceived[a] - ghostSent[a];
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _recordMove(address from, address to, uint256 amount) private {
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        ghostMovedTotal += amount;
    }

    function _recordSpend(address owner, address spender, uint256 amount) private {
        if (ghostAllowance[owner][spender] != type(uint256).max) {
            ghostAllowance[owner][spender] -= amount;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Clamped handlers: always succeed
    // ---------------------------------------------------------------------------------------------

    /// @notice A transfer bounded by the sender's balance. Always succeeds.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public countCall("transfer") {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);

        assertTrue(ok, "transfer returned false");
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited wrong amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrong amount");
        }
        _recordMove(from, to, amount);
        ghostSuccessfulTransfers++;
    }

    /// @notice Moves the sender's entire balance. The full-amount boundary.
    function transferAll(uint256 fromSeed, uint256 toSeed) public countCall("transferAll") {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = token.balanceOf(from);

        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transferAll returned false");

        if (from != to) assertEq(token.balanceOf(from), 0, "sender kept something back");
        _recordMove(from, to, amount);
        ghostSuccessfulTransfers++;
    }

    /// @notice One wei: the smallest non-zero amount.
    function transferOneWei(uint256 fromSeed, uint256 toSeed) public countCall("transferOneWei") {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (token.balanceOf(from) == 0) return;

        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, 1), "one-wei transfer returned false");
        if (from != to) assertEq(token.balanceOf(to), toBefore + 1, "one wei did not arrive whole");
        _recordMove(from, to, 1);
        ghostSuccessfulTransfers++;
    }

    /// @notice Sets an allowance to an arbitrary value, including zero and the unlimited sentinel.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public countCall("approve") {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");

        assertEq(token.allowance(owner, spender), amount, "approve did not set the exact amount");
        ghostAllowance[owner][spender] = amount;
        ghostApprovals++;
    }

    /// @notice Approves the unlimited sentinel, so transferFrom paths that must not decrement get hit.
    function approveMax(uint256 ownerSeed, uint256 spenderSeed) public countCall("approveMax") {
        approve(ownerSeed, spenderSeed, type(uint256).max);
    }

    /// @notice A transferFrom bounded by both the owner's balance and the spender's allowance.
    ///         Always succeeds.
    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount)
        public
        countCall("transferFrom")
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);

        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < held ? allowed : held);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        bool ok = token.transferFrom(owner, to, amount);

        assertTrue(ok, "transferFrom returned false");
        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self transferFrom changed balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner debited wrong amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrong amount");
        }
        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "unlimited allowance was decremented");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not spent exactly");
        }
        _recordMove(owner, to, amount);
        _recordSpend(owner, spender, amount);
        ghostSuccessfulTransferFroms++;
    }

    /// @notice Spends the whole allowance (or the whole balance, whichever is smaller).
    function transferFromAll(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed)
        public
        countCall("transferFromAll")
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        uint256 amount = allowed < held ? allowed : held;
        transferFrom(ownerSeed, spenderSeed, toSeed, amount);
        if (allowed != type(uint256).max && allowed <= held) {
            assertEq(token.allowance(owner, spender), 0, "spending the whole allowance left a remainder");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Unclamped handlers: arbitrary inputs, revert expected and verified
    // ---------------------------------------------------------------------------------------------

    /// @notice An arbitrary transfer. If it exceeds the balance it must revert with
    ///         `InsufficientBalance` and leave every balance untouched.
    function transferUnclamped(uint256 fromSeed, uint256 toSeed, uint256 amount) public countCall("transferUnclamped") {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertLe(amount, fromBefore, "transfer above balance succeeded");
            _recordMove(from, to, amount);
            ghostSuccessfulTransfers++;
        } catch (bytes memory reason) {
            assertGt(amount, fromBefore, "transfer within balance reverted");
            assertEq(
                reason,
                abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, from, fromBefore, amount),
                "wrong revert reason"
            );
            assertEq(token.balanceOf(from), fromBefore, "reverted transfer changed sender balance");
            assertEq(token.balanceOf(to), toBefore, "reverted transfer changed receiver balance");
            ghostExpectedReverts++;
        }
    }

    /// @notice An arbitrary transferFrom. The allowance is checked before the balance, so the
    ///         expected revert is `InsufficientAllowance` first and `InsufficientBalance` second,
    ///         and an unlimited allowance skips the first check entirely.
    function transferFromUnclamped(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount)
        public
        countCall("transferFromUnclamped")
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            assertTrue(ok, "transferFrom returned false");
            assertTrue(allowed == type(uint256).max || amount <= allowed, "transferFrom above allowance succeeded");
            assertLe(amount, held, "transferFrom above balance succeeded");
            _recordMove(owner, to, amount);
            _recordSpend(owner, spender, amount);
            ghostSuccessfulTransferFroms++;
        } catch (bytes memory reason) {
            bytes memory expected;
            if (allowed != type(uint256).max && amount > allowed) {
                expected = abi.encodeWithSelector(DaemonToken.InsufficientAllowance.selector, spender, allowed, amount);
            } else if (amount > held) {
                expected = abi.encodeWithSelector(DaemonToken.InsufficientBalance.selector, owner, held, amount);
            } else {
                revert("transferFrom within allowance and balance reverted");
            }
            assertEq(reason, expected, "wrong revert reason");
            assertEq(token.balanceOf(owner), held, "reverted transferFrom changed owner balance");
            assertEq(token.balanceOf(to), toBefore, "reverted transferFrom changed receiver balance");
            assertEq(token.allowance(owner, spender), allowed, "reverted transferFrom changed allowance");
            ghostExpectedReverts++;
        }
    }

    /// @notice Sending to the zero address must always revert, whatever the amount or sender.
    function transferToZero(uint256 fromSeed, uint256 amount) public countCall("transferToZero") {
        address from = _actor(fromSeed);
        uint256 before = token.balanceOf(from);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            revert("transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(DaemonToken.InvalidReceiver.selector, address(0)));
            assertEq(token.balanceOf(from), before);
            ghostExpectedReverts++;
        }
    }

    /// @notice Approving the zero address as spender must always revert and leave allowances alone.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) public countCall("approveZeroSpender") {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            revert("approve to the zero spender succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(DaemonToken.InvalidSpender.selector, address(0)));
            assertEq(token.allowance(owner, address(0)), 0);
            ghostExpectedReverts++;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Probes: things that must never work
    // ---------------------------------------------------------------------------------------------

    /// @notice Tries a privileged selector from a random actor (including the deployer). None exists,
    ///         so every one must fail, and the supply and the probed holder must be untouched.
    function probeAdminSelector(uint256 callerSeed, uint256 targetSeed, uint256 which)
        public
        countCall("probeAdminSelector")
    {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "seize(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setFee(uint256)"
        ];
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        uint256 targetBefore = token.balanceOf(target);
        uint256 callerBefore = token.balanceOf(caller);

        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], target, type(uint128).max);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);

        assertFalse(ok, "a privileged selector succeeded");
        assertEq(token.totalSupply(), SUPPLY, "a privileged selector changed the supply");
        assertEq(token.balanceOf(target), targetBefore, "a privileged selector moved a holder's balance");
        assertEq(token.balanceOf(caller), callerBefore, "a privileged selector changed the caller's balance");
        ghostProbes++;
    }

    /// @notice Ether sent to the token must bounce: there is no receive or fallback.
    function donateEther(uint256 fromSeed, uint256 amount) public countCall("donateEther") {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, 100 ether);
        vm.deal(from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
        ghostProbes++;
    }
}

/// @title DaemonToken invariants
/// @notice Properties that must hold after every random call sequence the handler produces.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract DaemonTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    DaemonTokenHandler handler;
    DaemonToken token;

    function setUp() public {
        handler = new DaemonTokenHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = DaemonTokenHandler.transfer.selector;
        selectors[1] = DaemonTokenHandler.transferAll.selector;
        selectors[2] = DaemonTokenHandler.transferOneWei.selector;
        selectors[3] = DaemonTokenHandler.approve.selector;
        selectors[4] = DaemonTokenHandler.approveMax.selector;
        selectors[5] = DaemonTokenHandler.transferFrom.selector;
        selectors[6] = DaemonTokenHandler.transferFromAll.selector;
        selectors[7] = DaemonTokenHandler.transferUnclamped.selector;
        selectors[8] = DaemonTokenHandler.transferFromUnclamped.selector;
        selectors[9] = DaemonTokenHandler.transferToZero.selector;
        selectors[10] = DaemonTokenHandler.approveZeroSpender.selector;
        selectors[11] = DaemonTokenHandler.probeAdminSelector.selector;
        selectors[12] = DaemonTokenHandler.donateEther.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The supply is fixed for life. No call sequence changes it.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "total supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "TOTAL_SUPPLY changed");
    }

    /// @dev Conservation: tokens are only ever moved between actors, so the actors' balances always
    ///      sum to exactly the supply. Any fee, burn, reflection or rounding in a transfer breaks this.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY, "sum of balances drifted from the supply");
    }

    /// @dev Every actor's balance is exactly what the handler's ledger says: the mint, plus every
    ///      amount it was sent, minus every amount it sent. Transfers move exactly `amount`.
    function invariant_balancesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.expectedBalance(a), "balance disagrees with the ledger");
        }
    }

    /// @dev Nobody can withdraw more than they were given: no actor other than the deployer may
    ///      hold more than the total it has received, and no balance may exceed the supply.
    function invariant_nobodyHoldsMoreThanReceived() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            uint256 ceiling = a == address(handler) ? SUPPLY : 0;
            ceiling += handler.ghostReceived(a);
            assertLe(token.balanceOf(a), ceiling, "an actor holds more than it received");
            assertLe(token.balanceOf(a), SUPPLY, "an actor holds more than the supply");
        }
    }

    /// @dev Allowances are exactly what was approved, minus exactly what was spent, and the unlimited
    ///      sentinel is never decremented. A spender never gains allowance from a transfer.
    function invariant_allowancesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance disagrees with the ledger"
                );
            }
        }
    }

    /// @dev The zero address can neither receive nor be approved, so it never holds anything.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            assertEq(token.allowance(handler.actors(i), address(0)), 0, "the zero address has an allowance");
        }
    }

    /// @dev The token never holds ether and its metadata never changes.
    function invariant_noEtherAndStableMetadata() public view {
        assertEq(address(token).balance, 0, "the token holds ether");
        assertEq(token.name(), "Daemon");
        assertEq(token.symbol(), "DAEMON");
        assertEq(uint256(token.decimals()), 18);
    }

    /// @dev The total the ledger says has moved is consistent with the deployer's drain: the deployer
    ///      can be down by at most what it sent, and everything anyone else holds came from somewhere.
    function invariant_ledgerIsInternallyConsistent() public view {
        uint256 n = handler.actorCount();
        uint256 sent;
        uint256 received;
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            sent += handler.ghostSent(a);
            received += handler.ghostReceived(a);
        }
        assertEq(sent, received, "the ledger's sent and received totals disagree");
        assertEq(sent, handler.ghostMovedTotal(), "the ledger's moved total disagrees");
    }

    /// @dev Not a property: prints what the campaign actually exercised, so a vacuous run is visible.
    function invariant_callSummary() public {
        console2_log("transfer", handler.calls("transfer"));
        console2_log("transferAll", handler.calls("transferAll"));
        console2_log("transferOneWei", handler.calls("transferOneWei"));
        console2_log("approve", handler.calls("approve"));
        console2_log("approveMax", handler.calls("approveMax"));
        console2_log("transferFrom", handler.calls("transferFrom"));
        console2_log("transferFromAll", handler.calls("transferFromAll"));
        console2_log("transferUnclamped", handler.calls("transferUnclamped"));
        console2_log("transferFromUnclamped", handler.calls("transferFromUnclamped"));
        console2_log("transferToZero", handler.calls("transferToZero"));
        console2_log("approveZeroSpender", handler.calls("approveZeroSpender"));
        console2_log("probeAdminSelector", handler.calls("probeAdminSelector"));
        console2_log("donateEther", handler.calls("donateEther"));
        console2_log("successful transfers", handler.ghostSuccessfulTransfers());
        console2_log("successful transferFroms", handler.ghostSuccessfulTransferFroms());
        console2_log("expected reverts", handler.ghostExpectedReverts());
        console2_log("approvals", handler.ghostApprovals());
        console2_log("probes", handler.ghostProbes());
    }

    function console2_log(string memory label, uint256 value) private {
        // Kept tiny so the summary does not drag the run: forge prints it only with -vv.
        emit log_named_uint(label, value);
    }
}
