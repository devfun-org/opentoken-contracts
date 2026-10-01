// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OpenToken} from "./OpenToken.sol";
import {OpenTokenMinter} from "./OpenTokenMinter.sol";
import {TreasuryVault} from "./TreasuryVault.sol";

/// Constructor-only bootstrap. No callable initialization or retained authority.
/// Timelock already exists; all later governance uses its normal delayed path.
contract OpenTokenGenesis {
    OpenToken public immutable token;
    TreasuryVault public immutable treasuryVault;
    OpenTokenMinter public immutable minter;

    constructor(
        IERC20 usdc,
        address governance,
        address finance,
        address guardian,
        uint256 authorization
    ) {
        // A new contract starts at nonce 1. TOKEN, Vault, then Minter are its only CREATEs.
        address predictedMinter = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"03"))))
        );
        token = new OpenToken(governance, predictedMinter);
        treasuryVault =
            new TreasuryVault(usdc, IERC20(address(token)), governance, finance, guardian);
        minter = new OpenTokenMinter(
            OpenTokenMinter.Configuration(
                token, usdc, treasuryVault, governance, address(0), authorization
            )
        );
        assert(address(minter) == predictedMinter);
    }
}
