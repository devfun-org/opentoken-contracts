// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// Shared immutable implementation; clones have no initializer or recipient setter.
/// @custom:security-contact hello@dev.fun
contract OpenTokenDepositReceiver {
    using SafeERC20 for IERC20;
    IERC20 public immutable token;
    address public immutable burner;

    constructor(IERC20 asset, address target) {
        require(address(asset) != address(0) && target != address(0), "configuration");
        token = asset;
        burner = target;
    }

    function collect() external returns (uint256 amount) {
        require(msg.sender == burner, "burner only");
        amount = token.balanceOf(address(this));
        require(amount != 0, "empty");
        token.safeTransfer(burner, amount);
    }
}

/// @custom:security-contact hello@dev.fun
contract OpenTokenDepositFactory {
    address public immutable implementation;
    mapping(address receiver => bool deployed) public isReceiver;
    event ReceiverCreated(bytes32 indexed salt, address indexed receiver);

    constructor(IERC20 token, address burner) {
        implementation = address(new OpenTokenDepositReceiver(token, burner));
    }

    function predict(bytes32 salt) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, salt);
    }

    /// Any caller may deploy early, but can never change the code or destination.
    function deploy(bytes32 salt) public returns (address receiver) {
        receiver = predict(salt);
        if (isReceiver[receiver]) return receiver;
        receiver = Clones.cloneDeterministic(implementation, salt);
        isReceiver[receiver] = true;
        emit ReceiverCreated(salt, receiver);
    }
}
