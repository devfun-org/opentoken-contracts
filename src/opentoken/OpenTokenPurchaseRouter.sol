// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPaidMintToken {
    function minter() external view returns (address);
}

interface IPaidMintMinter {
    function token() external view returns (address);
    function treasuryVault() external view returns (address);
    function USDC() external view returns (IERC20);
    function mintTo(uint256 amount, address recipient) external;
}

interface IReceiveAuthorizedUSDC {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// Optional immutable peripheral. A relayer pays gas while the holder signs
/// Circle ReceiveWithAuthorization. Its nonce commits to the entire mint order,
/// so copying the signature cannot redirect TOKEN or change the payment terms.
/// The core grants no privilege: this router is an ordinary USDC-paying minter.
contract OpenTokenPurchaseRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPaidMintToken public immutable token;
    IERC20 public immutable USDC;
    address public immutable treasuryVault;
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "OpenTokenPurchase(uint256 chainId,address router,address token,address minter,address payer,address recipient,uint256 amount,uint256 validAfter,uint256 validBefore,bytes32 salt)"
    );

    struct Order {
        address minter;
        address payer;
        address recipient;
        uint256 amount;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 salt;
    }
    mapping(bytes32 => bool) public purchased;
    error InvalidConfiguration();
    error InvalidOrder();
    error AlreadyPurchased();
    error IncorrectPayment();
    event Purchased(
        bytes32 indexed nonce, address indexed payer, address indexed recipient, uint256 amount
    );

    constructor(IPaidMintToken asset, IERC20 usdc, address vault) {
        if (address(asset).code.length == 0) revert InvalidConfiguration();
        if (
            address(usdc).code.length == 0 || address(usdc) == address(asset)
                || vault.code.length == 0 || vault == address(asset) || vault == address(usdc)
        ) {
            revert InvalidConfiguration();
        }
        token = asset;
        USDC = usdc;
        treasuryVault = vault;
    }

    function authorizationNonce(Order calldata order) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                block.chainid,
                address(this),
                address(token),
                order.minter,
                order.payer,
                order.recipient,
                order.amount,
                order.validAfter,
                order.validBefore,
                order.salt
            )
        );
    }

    function buy(Order calldata order, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        if (
            order.amount == 0 || order.payer == address(0) || order.payer == address(this)
                || order.recipient == address(0) || order.recipient == address(this)
                || order.recipient == address(token) || order.validBefore <= order.validAfter
        ) revert InvalidOrder();
        // A signed order always retains its original issuer. Never auto-retarget it.
        if (order.minter != token.minter() || order.minter.code.length == 0) revert InvalidOrder();
        IPaidMintMinter issuer = IPaidMintMinter(order.minter);
        if (
            issuer.token() != address(token) || address(issuer.USDC()) != address(USDC)
                || issuer.treasuryVault() != treasuryVault
        ) revert InvalidConfiguration();
        bytes32 nonce = authorizationNonce(order);
        if (purchased[nonce]) revert AlreadyPurchased();
        purchased[nonce] = true;
        uint256 beforeBalance = USDC.balanceOf(address(this));
        IReceiveAuthorizedUSDC(address(USDC))
            .receiveWithAuthorization(
                order.payer,
                address(this),
                order.amount,
                order.validAfter,
                order.validBefore,
                nonce,
                v,
                r,
                s
            );
        if (USDC.balanceOf(address(this)) != beforeBalance + order.amount) {
            revert IncorrectPayment();
        }
        USDC.forceApprove(order.minter, order.amount);
        issuer.mintTo(order.amount, order.recipient);
        if (USDC.balanceOf(address(this)) != beforeBalance) revert IncorrectPayment();
        USDC.forceApprove(order.minter, 0);
        emit Purchased(nonce, order.payer, order.recipient, order.amount);
    }
}
