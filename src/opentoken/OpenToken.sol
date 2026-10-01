// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// Immutable balances and permit state. The selected Minter enforces payment/cap/pause.
contract OpenToken is ERC20, ERC20Permit {
    address public immutable governanceTimelock;
    address public minter;
    // Identifies genesis even after all issued tokens have been burned.
    address public immutable firstMinter;

    error Unauthorized();
    error InvalidConfiguration();
    error StaleMinter();
    error InvalidAmount();
    error InvalidRecipient();
    event MinterChanged(address indexed previousMinter, address indexed nextMinter);

    constructor(address governance, address genesisMinter)
        ERC20("OpenTokens", "TOKEN")
        ERC20Permit("OpenTokens")
    {
        if (
            governance.code.length == 0 || governance == address(this)
                || genesisMinter == address(0) || genesisMinter == governance
                || genesisMinter == address(this)
        ) {
            revert InvalidConfiguration();
        }
        governanceTimelock = governance;
        // The genesis constructor creates this exact Minter in the same transaction.
        firstMinter = genesisMinter;
        minter = genesisMinter;
        emit MinterChanged(address(0), genesisMinter);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setMinter(address expectedCurrent, address next) external {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        if (minter != expectedCurrent) revert StaleMinter();
        if (
            next.code.length == 0 || next == address(this) || next == governanceTimelock
                || next == expectedCurrent
        ) revert InvalidConfiguration();
        minter = next;
        emit MinterChanged(expectedCurrent, next);
    }

    function mint(address recipient, uint256 amount) external {
        if (msg.sender != minter) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        _mint(recipient, amount);
    }

    /// Holder-only burn has no Credits entitlement and never refills mint capacity.
    function burn(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _burn(msg.sender, amount);
    }
}
