// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {ModularOpenTokenFixture} from "./helpers/ModularOpenTokenFixture.sol";
import {OpenTokenMinter} from "../src/opentoken/OpenTokenMinter.sol";
import {TreasuryVault} from "../src/opentoken/TreasuryVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OpenToken} from "../src/opentoken/OpenToken.sol";
import {OpenTokenTimelock} from "../src/opentoken/OpenTokenTimelock.sol";
import {OpenTokenDepositReceiver} from "../src/credits/OpenTokenDepositFactory.sol";
import {PaidOpenTokenCollector, IPaidOpenToken} from "../src/opentoken/PaidOpenTokenCollector.sol";
import {
    PaidOpenTokenUsdcFixture,
    PaidOpenTokenWalletFixture
} from "./helpers/PaidOpenTokenFixture.sol";

contract PaidCollectorTokenFixture is ERC20 {
    address public governanceTimelock;
    address public guardian;
    uint8 public fault;
    address public callback;
    bytes public callbackData;
    bytes4 public callbackError;

    constructor(address governance) ERC20("fault fixture", "F") {
        governanceTimelock = governance;
        guardian = msg.sender;
    }

    function setGovernance(address governance) external {
        governanceTimelock = governance;
    }

    function seed(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFault(uint8 mode) external {
        fault = mode;
    }

    function setCallback(address target, bytes calldata data) external {
        callback = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        return super.transfer(to, fault == 1 ? amount - 1 : amount);
    }

    function burn(uint256 amount) external {
        if (callback != address(0)) {
            (bool ok, bytes memory result) = callback.call(callbackData);
            require(!ok);
            callbackError = bytes4(result);
        }
        if (fault == 2) return;
        _burn(msg.sender, amount);
        if (fault == 3) _mint(guardian, 1);
    }
}

contract PaidOpenTokenCollectorTest is ModularOpenTokenFixture {
    PaidOpenTokenUsdcFixture private usdc;
    OpenToken private token;
    OpenTokenMinter private minter;
    TreasuryVault private vault;
    OpenTokenTimelock private timelock;
    PaidOpenTokenCollector private collector;
    bytes32 private constant SALT = keccak256("billing-account");

    function setUp() public {
        vm.warp(100);
        usdc = new PaidOpenTokenUsdcFixture(6);
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        timelock = new OpenTokenTimelock(2 days, proposers, executors);
        (token, vault, minter) = deploySuite(
            usdc,
            address(new PaidOpenTokenWalletFixture()),
            address(timelock),
            address(this),
            1000e6
        );
        collector =
            new PaidOpenTokenCollector(IPaidOpenToken(address(token)), vault, address(timelock));
        usdc.seed(address(this), 100e6);
        usdc.approve(address(minter), 100e6);
        minter.mintTo(40e6, collector.factory().predict(SALT));
        minter.mint(60e6);
    }

    function govern(address target, bytes memory data, bytes32 salt) private {
        timelock.schedule(target, 0, data, bytes32(0), salt, 2 days);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function testEarlyReceiverDeploymentCannotRedirectOrCollectFunds() public {
        address receiver = collector.factory().predict(SALT);
        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        assertEq(collector.factory().deploy(SALT), receiver);
        assertEq(collector.factory().deploy(SALT), receiver);
        assertEq(address(OpenTokenDepositReceiver(receiver).token()), address(token));
        assertEq(OpenTokenDepositReceiver(receiver).burner(), address(collector));

        vm.prank(outsider);
        vm.expectRevert("burner only");
        OpenTokenDepositReceiver(receiver).collect();
        assertEq(token.balanceOf(receiver), 40e6);

        vm.prank(outsider);
        assertEq(collector.convert(SALT), 1);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(outsider), 0);
        assertEq(collector.totalBurned(), 40e6);
        assertEq(minter.mintedTotal(), 100e6);
    }

    function testFuzzReceiverRejectsZeroBindings(bool zeroToken, bool zeroCollector) public {
        IERC20 asset = zeroToken ? IERC20(address(0)) : IERC20(address(token));
        address target = zeroCollector ? address(0) : address(collector);
        if (zeroToken || zeroCollector) {
            vm.expectRevert("configuration");
            new OpenTokenDepositReceiver(asset, target);
        } else {
            OpenTokenDepositReceiver receiver = new OpenTokenDepositReceiver(asset, target);
            assertEq(address(receiver.token()), address(token));
            assertEq(receiver.burner(), address(collector));
        }
    }

    function testMintPauseLeavesConversionAvailableAndAccountingIsExact() public {
        vault.pause();
        assertFalse(collector.paused());
        address receiver = collector.factory().predict(SALT);
        token.transfer(address(collector), 5e6);
        token.transfer(receiver, 55e6);
        assertEq(collector.governanceTimelock(), address(timelock));
        assertEq(address(collector.token()), address(token));
        vm.prank(makeAddr("any executor"));
        uint256 id = collector.convert(SALT);
        (address source, uint256 amount) = collector.conversions(id);
        assertEq(source, receiver);
        assertEq(amount, 95e6);
        assertEq(collector.totalBurned(), 95e6);
        assertEq(token.totalSupply(), 5e6);
        assertEq(token.balanceOf(address(collector)), 5e6);
        assertEq(minter.mintedTotal(), 100e6);
        assertEq(collector.nextConversionId(), 1);
        vm.expectRevert("empty");
        collector.convert(SALT);
    }

    function testConversionPauseSeparateRepeatableAndResumeRequiresCurrentIncident() public {
        collector.pauseConversions();
        assertFalse(vault.emergencyPaused());
        vm.expectRevert(PaidOpenTokenCollector.ConversionsPaused.selector);
        collector.convert(SALT);
        bytes memory stale = abi.encodeCall(collector.resumeConversions, (1));
        timelock.schedule(address(collector), 0, stale, bytes32(0), "stale", 2 days);
        vm.expectRevert();
        timelock.execute(address(collector), 0, stale, bytes32(0), "stale");
        vm.prank(address(timelock));
        collector.pauseConversions();
        assertEq(collector.conversionIncidentNonce(), 2);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(PaidOpenTokenCollector.InvalidRecovery.selector);
        timelock.execute(address(collector), 0, stale, bytes32(0), "stale");
        assertTrue(collector.paused());
        govern(address(collector), abi.encodeCall(collector.resumeConversions, (2)), "current");
        collector.convert(SALT);
        collector.pauseConversions();
        assertEq(collector.conversionIncidentNonce(), 3);
    }

    function testGuardianRotationAlsoRemovesCollectorPauseAuthority() public {
        address next = makeAddr("replacement guardian");
        collector.pauseConversions();
        govern(address(vault), abi.encodeCall(vault.setGuardian, (next)), "guardian");
        vm.expectRevert(PaidOpenTokenCollector.Unauthorized.selector);
        collector.pauseConversions();
        vm.prank(next);
        collector.pauseConversions();
        assertEq(collector.conversionIncidentNonce(), 2);
        vm.prank(next);
        vm.expectRevert(PaidOpenTokenCollector.Unauthorized.selector);
        collector.resumeConversions(2);
        govern(address(collector), abi.encodeCall(collector.resumeConversions, (2)), "resume");
        vm.prank(address(timelock));
        vm.expectRevert(PaidOpenTokenCollector.InvalidRecovery.selector);
        collector.resumeConversions(2);
    }

    function testUnauthorizedAndInvalidConfiguration() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(PaidOpenTokenCollector.Unauthorized.selector);
        collector.pauseConversions();
        vm.expectRevert(PaidOpenTokenCollector.Unauthorized.selector);
        collector.resumeConversions(0);
        vm.expectRevert(PaidOpenTokenCollector.InvalidConfiguration.selector);
        new PaidOpenTokenCollector(IPaidOpenToken(address(0)), vault, address(timelock));
    }

    function testFuzzInvalidCollectorGovernance(bool self) public {
        PaidCollectorTokenFixture invalid = new PaidCollectorTokenFixture(address(0));
        if (self) invalid.setGovernance(address(invalid));
        address invalidGovernance = invalid.governanceTimelock();
        vm.expectRevert(PaidOpenTokenCollector.InvalidConfiguration.selector);
        new PaidOpenTokenCollector(IPaidOpenToken(address(invalid)), vault, invalidGovernance);
    }

    function testFuzzInexactCollectionOrBurnRollsBackEverything(uint8 raw) public {
        uint8 mode = uint8(bound(raw, 1, 3));
        PaidCollectorTokenFixture asset = new PaidCollectorTokenFixture(address(timelock));
        PaidOpenTokenCollector target = new PaidOpenTokenCollector(
            IPaidOpenToken(address(asset)),
            new TreasuryVault(
                usdc,
                IERC20(address(asset)),
                address(timelock),
                address(new PaidOpenTokenWalletFixture()),
                address(this)
            ),
            address(timelock)
        );
        address receiver = target.factory().predict(SALT);
        asset.seed(receiver, 10e6);
        asset.setFault(mode);
        vm.expectRevert(PaidOpenTokenCollector.IncorrectConversion.selector);
        target.convert(SALT);
        assertEq(asset.balanceOf(receiver), 10e6);
        assertEq(asset.totalSupply(), 10e6);
        assertEq(target.nextConversionId(), 0);
        assertEq(target.totalBurned(), 0);
        asset.setFault(0);
        target.convert(SALT);
        assertEq(asset.totalSupply(), 0);
    }

    function testFuzzBurnCallbackCannotReenterConversionOrPause(uint8 raw) public {
        uint256 mode = bound(raw, 0, 2);
        PaidCollectorTokenFixture asset = new PaidCollectorTokenFixture(address(timelock));
        PaidOpenTokenCollector target = new PaidOpenTokenCollector(
            IPaidOpenToken(address(asset)),
            new TreasuryVault(
                usdc,
                IERC20(address(asset)),
                address(timelock),
                address(new PaidOpenTokenWalletFixture()),
                address(this)
            ),
            address(timelock)
        );
        asset.seed(target.factory().predict(SALT), 1);
        bytes memory data = mode == 0
            ? abi.encodeCall(target.convert, (SALT))
            : mode == 1
                ? abi.encodeCall(target.pauseConversions, ())
                : abi.encodeCall(target.resumeConversions, (0));
        asset.setCallback(address(target), data);
        target.convert(SALT);
        assertEq(asset.callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }
}
