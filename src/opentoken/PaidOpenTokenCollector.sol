// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {TreasuryVault} from "./TreasuryVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    OpenTokenDepositFactory,
    OpenTokenDepositReceiver
} from "../credits/OpenTokenDepositFactory.sol";

interface IPaidOpenToken is IERC20 {
    function burn(uint256 amount) external;
    function governanceTimelock() external view returns (address);
}

/// Conversion has its own incident state, but follows the fixed Vault's current
/// guardian. Mint/treasury emergencies do not automatically block conversion.
contract PaidOpenTokenCollector is ReentrancyGuard {
    IPaidOpenToken public immutable token;
    TreasuryVault public immutable treasuryVault;
    address public immutable governanceTimelock;
    OpenTokenDepositFactory public immutable factory;
    bool public paused;
    uint256 public conversionIncidentNonce;
    uint256 public nextConversionId;
    uint256 public totalBurned;

    struct Conversion {
        address source;
        uint256 amount;
    }
    mapping(uint256 => Conversion) public conversions;

    error InvalidConfiguration();
    error Unauthorized();
    error ConversionsPaused();
    error InvalidRecovery();
    error IncorrectConversion();
    event Converted(uint256 indexed conversionId, address indexed source, uint256 amount);
    event ConversionsStopped(uint256 incidentNonce);
    event ConversionsResumed(uint256 incidentNonce);

    constructor(IPaidOpenToken asset, TreasuryVault vault, address governance) {
        if (address(asset).code.length == 0) revert InvalidConfiguration();
        if (
            governance.code.length == 0 || governance == address(asset)
                || address(vault).code.length == 0 || address(vault.token()) != address(asset)
                || vault.governanceTimelock() != governance
                || asset.governanceTimelock() != governance
        ) {
            revert InvalidConfiguration();
        }
        token = asset;
        treasuryVault = vault;
        governanceTimelock = governance;
        factory = new OpenTokenDepositFactory(asset, address(this));
    }

    function pauseConversions() external nonReentrant {
        if (msg.sender != treasuryVault.guardian() && msg.sender != governanceTimelock) {
            revert Unauthorized();
        }
        paused = true;
        emit ConversionsStopped(++conversionIncidentNonce);
    }

    function resumeConversions(uint256 expectedIncident) external nonReentrant {
        if (msg.sender != governanceTimelock) revert Unauthorized();
        if (!paused || expectedIncident != conversionIncidentNonce) revert InvalidRecovery();
        paused = false;
        emit ConversionsResumed(conversionIncidentNonce);
    }

    function convert(bytes32 salt) external nonReentrant returns (uint256 id) {
        if (paused) revert ConversionsPaused();
        address source = factory.deploy(salt);
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 supplyBefore = token.totalSupply();
        uint256 amount = OpenTokenDepositReceiver(source).collect();
        if (token.balanceOf(address(this)) != balanceBefore + amount) revert IncorrectConversion();
        token.burn(amount);
        if (
            token.balanceOf(address(this)) != balanceBefore
                || token.totalSupply() != supplyBefore - amount
        ) revert IncorrectConversion();
        id = ++nextConversionId;
        totalBurned += amount;
        conversions[id] = Conversion(source, amount);
        emit Converted(id, source, amount);
    }
}
