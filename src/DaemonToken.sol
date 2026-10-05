// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Daemon (DAEMON)
/// @notice A plain, fixed-supply ERC-20 community token for the people who keep the IMD daemon running.
/// @dev Design constraints, all deliberate:
///      - The whole supply (1,000,000,000 * 10**18) is minted once, in the constructor, to `msg.sender`.
///        Under the IMD launch flow `msg.sender` is the ProjectFactory, which then distributes it.
///      - There is no owner, no admin role, no minter, no pauser, no blocklist, no fee, no burn hook,
///        no upgrade path. Every function below is either an ERC-20 view or an ERC-20 transfer or
///        approval that acts only on the caller's own balance or allowance.
///      - `totalSupply` can never increase after construction. It is a constant written once.
///      - Transfers move exactly `amount` from `from` to `to`: no rounding, no tax, no reflection.
///      - No external calls, no DELEGATECALL, no CALLCODE, no SELFDESTRUCT anywhere in the runtime.
///      The implementation is self-contained rather than inherited, so the audited surface is this
///      file alone. Semantics follow the ERC-20 standard and match OpenZeppelin v5 behaviour:
///      reverts on insufficient balance or allowance, reverts on the zero address as sender,
///      receiver or spender, and an allowance of `type(uint256).max` is not decremented.
contract DaemonToken {
    // ---------------------------------------------------------------------------------------------
    // ERC-20 metadata
    // ---------------------------------------------------------------------------------------------

    /// @notice Token name.
    string public constant name = "Daemon";

    /// @notice Token symbol.
    string public constant symbol = "DAEMON";

    /// @notice Token decimals.
    uint8 public constant decimals = 18;

    /// @notice The fixed supply in minor units: 1,000,000,000 whole tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ---------------------------------------------------------------------------------------------
    // Events (ERC-20)
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice `sender` tried to move `needed` but holds only `balance`.
    error InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /// @notice `spender` tried to spend `needed` of `owner`'s tokens but is allowed only `allowance`.
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /// @notice The zero address was used as a sender.
    error InvalidSender(address sender);

    /// @notice The zero address was used as a receiver.
    error InvalidReceiver(address receiver);

    /// @notice The zero address was used as an approver.
    error InvalidApprover(address approver);

    /// @notice The zero address was used as a spender.
    error InvalidSpender(address spender);

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the entire fixed supply to the deployer. This is the only mint that ever happens.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20 views
    // ---------------------------------------------------------------------------------------------

    /// @notice Total supply. Constant for the life of the contract.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @notice Balance of `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Remaining amount `spender` may move on behalf of `owner`.
    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20 actions
    // ---------------------------------------------------------------------------------------------

    /// @notice Moves exactly `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to exactly `amount`.
    /// @dev Standard ERC-20 approve. Callers changing a non-zero allowance to another non-zero
    ///      value should set it to zero first if they care about the known approve race.
    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Moves exactly `amount` from `from` to `to`, spending the caller's allowance.
    /// @dev An allowance of `type(uint256).max` is treated as unlimited and is not decremented.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0)) revert InvalidSender(address(0));
        if (to == address(0)) revert InvalidReceiver(address(0));

        uint256 fromBalance = _balances[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);

        unchecked {
            // Safe: fromBalance >= amount was checked above, and the receiver's balance cannot
            // exceed TOTAL_SUPPLY because the sum of all balances is exactly TOTAL_SUPPLY.
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0)) revert InvalidApprover(address(0));
        if (spender == address(0)) revert InvalidSpender(address(0));
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(spender, current, amount);
        unchecked {
            _allowances[owner][spender] = current - amount;
        }
    }
}
