// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {OpenToken} from "./OpenToken.sol";
import {TreasuryVault} from "./TreasuryVault.sol";

/// Public, exact-USDC issuance. No wallet roles, public toggle or replenishable cap.
contract OpenTokenMinter is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    struct Configuration {
        OpenToken token;
        IERC20 usdc;
        TreasuryVault treasuryVault;
        address governanceTimelock;
        address predecessor;
        uint256 initialAuthorization;
    }
    OpenToken public immutable token;
    IERC20 public immutable USDC;
    TreasuryVault public immutable treasuryVault;
    address public immutable governanceTimelock;
    address public immutable predecessor;
    address public successor;
    bool public initialized;
    bool public retired;
    uint256 public authorizedMintTotal;
    uint256 public mintedTotal;

    struct PaymentAuthorization {
        address payer;
        address recipient;
        address executor;
        uint256 amount;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }
    bytes32 public constant PAYMENT_TYPEHASH = keccak256(
        "OpenTokenPayment(address token,address asset,address vault,address payer,address recipient,address executor,uint256 amount,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    mapping(address => mapping(bytes32 => bool)) public authorizationUsed;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidInitialization();
    error MintUnavailable();
    error InvalidAmount();
    error InvalidRecipient();
    error TreasurySelfPayment();
    error IncorrectReceipt();
    error InsufficientMintAuthorization();
    error InvalidMintAuthorization();
    error InvalidPaymentAuthorization();
    event Issued(
        address indexed payer,
        address indexed recipient,
        address indexed asset,
        uint256 paymentAmount,
        uint256 issuedAmount,
        address destination
    );
    event MintAuthorizationIncreased(uint256 previousTotal, uint256 newTotal);
    event Initialized(address indexed predecessor, uint256 authorization, uint256 minted);
    event Retired(address indexed successor);
    event PaymentAuthorizationCancelled(address indexed payer, bytes32 indexed nonce);

    constructor(Configuration memory config) EIP712("OpenTokenMinter", "1") {
        if (
            address(config.token).code.length == 0 || address(config.usdc).code.length == 0
                || address(config.treasuryVault).code.length == 0
                || config.governanceTimelock.code.length == 0
                || address(config.token) == address(config.usdc)
                || address(config.treasuryVault) == address(config.token)
                || address(config.treasuryVault) == address(config.usdc)
                || IERC20Metadata(address(config.usdc)).decimals() != 6
                || config.token.governanceTimelock() != config.governanceTimelock
                || config.treasuryVault.governanceTimelock() != config.governanceTimelock
                || address(config.treasuryVault.token()) != address(config.token)
                || address(config.treasuryVault.USDC()) != address(config.usdc)
                || (config.predecessor != address(0) && config.predecessor.code.length == 0)
        ) revert InvalidConfiguration();
        token = config.token;
        USDC = config.usdc;
        treasuryVault = config.treasuryVault;
        governanceTimelock = config.governanceTimelock;
        predecessor = config.predecessor;
        if (config.predecessor == address(0)) {
            if (token.firstMinter() != address(this) || token.minter() != address(this)) {
                revert InvalidInitialization();
            }
            initialized = true;
            authorizedMintTotal = config.initialAuthorization;
            emit Initialized(address(0), config.initialAuthorization, 0);
        } else if (config.initialAuthorization != 0) {
            revert InvalidInitialization();
        }
    }

    modifier onlyGovernance() {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        _;
    }

    function initializeFromPredecessor() external nonReentrant onlyGovernance {
        if (initialized || predecessor == address(0) || token.minter() != address(this)) {
            revert InvalidInitialization();
        }
        OpenTokenMinter previous = OpenTokenMinter(predecessor);
        if (
            !previous.retired() || previous.successor() != address(this)
                || address(previous.token()) != address(token)
                || address(previous.USDC()) != address(USDC)
                || address(previous.treasuryVault()) != address(treasuryVault)
                || previous.governanceTimelock() != governanceTimelock
        ) revert InvalidInitialization();
        uint256 authorization = previous.authorizedMintTotal();
        uint256 minted = previous.mintedTotal();
        if (minted > authorization) revert InvalidInitialization();
        initialized = true;
        authorizedMintTotal = authorization;
        mintedTotal = minted;
        emit Initialized(predecessor, authorization, minted);
    }

    /// Schedule retire + Token.setMinter(expected, next) + next.initialize as one batch.
    function retire(address next) external nonReentrant onlyGovernance {
        _requireActive();
        if (next.code.length == 0 || next == address(this)) revert InvalidConfiguration();
        OpenTokenMinter candidate = OpenTokenMinter(next);
        if (
            candidate.predecessor() != address(this) || candidate.initialized()
                || address(candidate.token()) != address(token)
                || address(candidate.USDC()) != address(USDC)
                || address(candidate.treasuryVault()) != address(treasuryVault)
                || candidate.governanceTimelock() != governanceTimelock
        ) revert InvalidConfiguration();
        retired = true;
        successor = next;
        emit Retired(next);
    }

    function mint(uint256 amount) external nonReentrant {
        _paidMint(msg.sender, msg.sender, amount);
    }

    function mintTo(uint256 amount, address recipient) external nonReentrant {
        _paidMint(msg.sender, recipient, amount);
    }

    /// Explicit payer consent for delegated purchases, including Safe-funded Timelock batches.
    /// USDC approval is still required; allowance alone never authorizes this entry.
    function mintWithAuthorization(PaymentAuthorization calldata order, bytes calldata signature)
        external
        nonReentrant
    {
        if (
            order.payer == address(0) || msg.sender != order.executor
                || block.timestamp <= order.validAfter || block.timestamp >= order.validBefore
                || authorizationUsed[order.payer][order.nonce]
                || !SignatureChecker.isValidSignatureNow(
                    order.payer, paymentDigest(order), signature
                )
        ) revert InvalidPaymentAuthorization();
        authorizationUsed[order.payer][order.nonce] = true;
        _paidMint(order.payer, order.recipient, order.amount);
    }

    function paymentDigest(PaymentAuthorization calldata order) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PAYMENT_TYPEHASH,
                    address(token),
                    address(USDC),
                    address(treasuryVault),
                    order.payer,
                    order.recipient,
                    order.executor,
                    order.amount,
                    order.validAfter,
                    order.validBefore,
                    order.nonce
                )
            )
        );
    }

    function cancelAuthorization(bytes32 nonce) external {
        authorizationUsed[msg.sender][nonce] = true;
        emit PaymentAuthorizationCancelled(msg.sender, nonce);
    }

    function _requireActive() private view {
        if (!initialized || retired || token.minter() != address(this)) revert MintUnavailable();
    }

    function _paidMint(address payer, address recipient, uint256 amount) private {
        _requireActive();
        if (treasuryVault.emergencyPaused()) revert MintUnavailable();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0) || recipient == address(token) || recipient == address(this)) {
            revert InvalidRecipient();
        }
        address destination = address(treasuryVault);
        if (payer == destination) revert TreasurySelfPayment();
        if (amount > remainingMintAuthorization()) revert InsufficientMintAuthorization();
        mintedTotal += amount;
        uint256 beforeBalance = USDC.balanceOf(destination);
        USDC.safeTransferFrom(payer, destination, amount);
        uint256 afterBalance = USDC.balanceOf(destination);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert IncorrectReceipt();
        }
        token.mint(recipient, amount);
        emit Issued(payer, recipient, address(USDC), amount, amount, destination);
    }

    function remainingMintAuthorization() public view returns (uint256) {
        return authorizedMintTotal - mintedTotal;
    }

    function increaseMintAuthorization(uint256 newTotal) external nonReentrant onlyGovernance {
        _requireActive();
        uint256 previous = authorizedMintTotal;
        if (newTotal <= previous) revert InvalidMintAuthorization();
        authorizedMintTotal = newTotal;
        emit MintAuthorizationIncreased(previous, newTotal);
    }
}
