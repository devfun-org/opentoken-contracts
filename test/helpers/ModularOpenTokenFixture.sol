// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {OpenTokenGenesis} from "../../src/opentoken/OpenTokenGenesis.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OpenToken} from "../../src/opentoken/OpenToken.sol";
import {OpenTokenMinter} from "../../src/opentoken/OpenTokenMinter.sol";
import {TreasuryVault} from "../../src/opentoken/TreasuryVault.sol";

abstract contract ModularOpenTokenFixture is Test {
    function deploySuite(
        IERC20 usdc,
        address finance,
        address governance,
        address guardian,
        uint256 cap
    ) internal returns (OpenToken token, TreasuryVault vault, OpenTokenMinter minter) {
        OpenTokenGenesis genesis = new OpenTokenGenesis(usdc, governance, finance, guardian, cap);
        return (genesis.token(), genesis.treasuryVault(), genesis.minter());
    }
}
