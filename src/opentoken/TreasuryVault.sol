// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Every USDC outflow follows the same fixed-delay, balance-reserving queue.
/// There is no allowance, arbitrary call, upgrade, rescue or immediate withdrawal.
contract TreasuryVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant WITHDRAWAL_DELAY = 24 hours;
    IERC20 public immutable USDC;
    IERC20 public immutable token;
    address public guardian;
    bool public emergencyPaused;
    uint256 public incidentNonce;
    address public immutable governanceTimelock;
    address public financeSafe;
    uint256 public nextWithdrawalId;
    mapping(uint256 => uint256) public reservedByIncident;

    enum Status {
        Missing,
        Pending,
        Ready,
        Executed,
        Cancelled,
        Invalidated
    }

    struct Withdrawal {
        address recipient;
        uint256 amount;
        uint256 readyAt;
        uint256 incidentNonce;
        bool executed;
        bool cancelled;
    }
    mapping(uint256 => Withdrawal) public withdrawals;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidWithdrawal();
    error WithdrawalsPaused();
    error InsufficientUnreservedBalance();
    error InsufficientBacking();
    error InvalidWithdrawalStatus();
    error IncorrectTransfer();
    error PauseRequired();
    error InvalidRecovery();
    event EmergencyPaused(address indexed authority, uint256 incidentNonce);
    event EmergencyResumed(uint256 incidentNonce);
    event GuardianChanged(address indexed previousGuardian, address indexed nextGuardian);

    event WithdrawalRequested(
        uint256 indexed id,
        address indexed recipient,
        uint256 amount,
        uint256 readyAt,
        uint256 incidentNonce
    );
    event WithdrawalCancelled(uint256 indexed id);
    event WithdrawalExecuted(uint256 indexed id, address indexed recipient, uint256 amount);
    event FinanceSafeChanged(address indexed previousSafe, address indexed nextSafe);

    constructor(
        IERC20 asset,
        IERC20 state,
        address governance,
        address finance,
        address initialGuardian
    ) {
        // Independent deployment: the Token and governance must already exist.
        if (
            address(asset).code.length == 0 || address(state).code.length == 0
                || governance.code.length == 0 || address(asset) == address(state)
                || governance == address(asset) || governance == address(state)
        ) revert InvalidConfiguration();
        USDC = asset;
        token = state;
        governanceTimelock = governance;
        _validateFinanceSafe(finance);
        financeSafe = finance;
        _validateGuardian(initialGuardian);
        guardian = initialGuardian;
    }

    function reservedUSDC() public view returns (uint256) {
        return reservedByIncident[incidentNonce];
    }

    function availableUSDC() external view returns (uint256) {
        uint256 balance = USDC.balanceOf(address(this));
        uint256 reserved = reservedUSDC();
        return balance > reserved ? balance - reserved : 0;
    }

    function withdrawalStatus(uint256 id) public view returns (Status) {
        Withdrawal storage request = withdrawals[id];
        if (request.recipient == address(0)) return Status.Missing;
        if (request.executed) return Status.Executed;
        if (request.cancelled) return Status.Cancelled;
        if (request.incidentNonce != incidentNonce) return Status.Invalidated;
        return block.timestamp < request.readyAt ? Status.Pending : Status.Ready;
    }

    function requestWithdrawal(address recipient, uint256 amount)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (msg.sender != financeSafe) revert Unauthorized();
        if (emergencyPaused) revert WithdrawalsPaused();
        if (recipient == address(0) || recipient == address(this) || amount == 0) {
            revert InvalidWithdrawal();
        }
        uint256 incident = incidentNonce;
        uint256 balance = USDC.balanceOf(address(this));
        uint256 reserved = reservedByIncident[incident];
        if (balance < reserved || amount > balance - reserved) {
            revert InsufficientUnreservedBalance();
        }
        id = ++nextWithdrawalId;
        uint256 readyAt = block.timestamp + WITHDRAWAL_DELAY;
        withdrawals[id] = Withdrawal(recipient, amount, readyAt, incident, false, false);
        reservedByIncident[incident] = reserved + amount;
        emit WithdrawalRequested(id, recipient, amount, readyAt, incident);
    }

    function cancelWithdrawal(uint256 id) external nonReentrant {
        if (msg.sender != financeSafe && msg.sender != guardian && msg.sender != governanceTimelock)
        {
            revert Unauthorized();
        }
        Status status = withdrawalStatus(id);
        if (status != Status.Pending && status != Status.Ready) revert InvalidWithdrawalStatus();
        Withdrawal storage request = withdrawals[id];
        request.cancelled = true;
        reservedByIncident[request.incidentNonce] -= request.amount;
        emit WithdrawalCancelled(id);
    }

    function executeWithdrawal(uint256 id) external nonReentrant {
        if (emergencyPaused) revert WithdrawalsPaused();
        if (withdrawalStatus(id) != Status.Ready) revert InvalidWithdrawalStatus();
        Withdrawal storage request = withdrawals[id];
        uint256 balance = USDC.balanceOf(address(this));
        if (balance < reservedByIncident[request.incidentNonce]) revert InsufficientBacking();
        uint256 recipientBefore = USDC.balanceOf(request.recipient);
        request.executed = true;
        reservedByIncident[request.incidentNonce] -= request.amount;
        USDC.safeTransfer(request.recipient, request.amount);
        uint256 balanceAfter = USDC.balanceOf(address(this));
        uint256 recipientAfter = USDC.balanceOf(request.recipient);
        if (
            balanceAfter > balance || balance - balanceAfter != request.amount
                || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != request.amount
        ) revert IncorrectTransfer();
        emit WithdrawalExecuted(id, request.recipient, request.amount);
    }

    function setFinanceSafe(address next) external nonReentrant {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        if (!emergencyPaused) revert PauseRequired();
        _validateFinanceSafe(next);
        address previous = financeSafe;
        financeSafe = next;
        emit FinanceSafeChanged(previous, next);
    }

    function pause() external nonReentrant {
        if (msg.sender != guardian && msg.sender != governanceTimelock) revert Unauthorized();
        emergencyPaused = true;
        emit EmergencyPaused(msg.sender, ++incidentNonce);
    }

    function resume(uint256 expectedIncidentNonce) external nonReentrant {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        if (!emergencyPaused || expectedIncidentNonce != incidentNonce) revert InvalidRecovery();
        emergencyPaused = false;
        emit EmergencyResumed(incidentNonce);
    }

    // Rotation never depends on a recovery that a compromised Guardian can stale.
    function setGuardian(address next) external nonReentrant {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        _validateGuardian(next);
        address previous = guardian;
        guardian = next;
        emit GuardianChanged(previous, next);
    }

    function _validateGuardian(address candidate) private view {
        if (
            candidate == address(0) || candidate == address(this) || candidate == address(USDC)
                || candidate == address(token) || candidate == governanceTimelock
        ) revert InvalidConfiguration();
    }

    function _validateFinanceSafe(address candidate) private view {
        if (
            candidate.code.length == 0 || candidate == address(this) || candidate == address(USDC)
                || candidate == address(token) || candidate == governanceTimelock
        ) revert InvalidConfiguration();
    }
}
