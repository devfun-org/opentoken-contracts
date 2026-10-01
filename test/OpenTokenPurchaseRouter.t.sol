// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {ModularOpenTokenFixture} from "./helpers/ModularOpenTokenFixture.sol";
import {OpenTokenMinter} from "../src/opentoken/OpenTokenMinter.sol";
import {TreasuryVault} from "../src/opentoken/TreasuryVault.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OpenToken} from "../src/opentoken/OpenToken.sol";
import {
    OpenTokenPurchaseRouter,
    IPaidMintToken
} from "../src/opentoken/OpenTokenPurchaseRouter.sol";
import {
    PaidOpenTokenUsdcFixture,
    PaidOpenTokenWalletFixture
} from "./helpers/PaidOpenTokenFixture.sol";

contract AuthorizedUsdcFixture is PaidOpenTokenUsdcFixture, EIP712 {
    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    bool public shortAuthorization;
    constructor() PaidOpenTokenUsdcFixture(6) EIP712("USDC fixture", "2") {}

    function setShortAuthorization(bool value) external {
        shortAuthorization = value;
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

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
    ) external {
        require(
            to == msg.sender && block.timestamp > validAfter && block.timestamp < validBefore,
            "authorization window or payee"
        );
        require(!authorizationState[from][nonce], "used");
        bytes32 typehash = keccak256(
            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );
        require(
            ECDSA.recover(
                _hashTypedDataV4(
                    keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce))
                ),
                v,
                r,
                s
            ) == from,
            "signature"
        );
        authorizationState[from][nonce] = true;
        _transfer(from, to, shortAuthorization ? value - 1 : value);
    }
}

contract RouterMintFaultFixture {
    IERC20 public USDC;
    address public token;
    address public treasuryVault;

    constructor(IERC20 usdc, address asset, address vault) {
        USDC = usdc;
        token = asset;
        treasuryVault = vault;
    }

    function mintTo(uint256 amount, address) external {
        USDC.transferFrom(msg.sender, address(this), amount - 1);
    }
}

contract OpenTokenPurchaseRouterTest is ModularOpenTokenFixture {
    AuthorizedUsdcFixture private usdc;
    OpenToken private token;
    OpenTokenMinter private minter;
    TreasuryVault private vault;
    OpenTokenPurchaseRouter private router;
    uint256 private constant KEY = 0x1234;
    address private payer;
    address private recipient;

    function setUp() public {
        vm.warp(100);
        payer = vm.addr(KEY);
        recipient = makeAddr("recipient");
        usdc = new AuthorizedUsdcFixture();
        (token, vault, minter) = deploySuite(
            usdc,
            address(new PaidOpenTokenWalletFixture()),
            address(new PaidOpenTokenWalletFixture()),
            address(this),
            1000e6
        );
        router = new OpenTokenPurchaseRouter(IPaidMintToken(address(token)), usdc, address(vault));
        usdc.seed(payer, 1000e6);
    }

    function order(uint256 amount) private view returns (OpenTokenPurchaseRouter.Order memory) {
        return OpenTokenPurchaseRouter.Order(
            address(minter),
            payer,
            recipient,
            amount,
            0,
            block.timestamp + 600,
            keccak256("order-one")
        );
    }

    function sign(OpenTokenPurchaseRouter target, OpenTokenPurchaseRouter.Order memory intent)
        private
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                usdc.domainSeparator(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
                        ),
                        intent.payer,
                        address(target),
                        intent.amount,
                        intent.validAfter,
                        intent.validBefore,
                        target.authorizationNonce(intent)
                    )
                )
            )
        );
        return vm.sign(KEY, digest);
    }

    function testFuzzRelayerCannotRedirectPaymentAndHoldsNoFunds(uint96 raw) public {
        uint256 amount = bound(raw, 1, 1000e6);
        OpenTokenPurchaseRouter.Order memory intent = order(amount);
        usdc.seed(address(router), 100);
        (uint8 v, bytes32 r, bytes32 s) = sign(router, intent);
        vm.prank(makeAddr("relayer"));
        router.buy(intent, v, r, s);
        assertEq(payer.balance, 0);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(vault)), amount);
        assertEq(usdc.balanceOf(address(router)), 100);
        assertEq(usdc.allowance(address(router), address(minter)), 0);
        assertTrue(router.purchased(router.authorizationNonce(intent)));
        assertEq(minter.mintedTotal(), amount);
        assertEq(address(router.token()), address(token));
        assertEq(address(router.USDC()), address(usdc));
        vm.expectRevert(OpenTokenPurchaseRouter.AlreadyPurchased.selector);
        router.buy(intent, v, r, s);
    }

    function testFuzzSignedNonceBindsEveryOrderField(uint8 raw) public {
        uint256 mode = bound(raw, 0, 7);
        OpenTokenPurchaseRouter.Order memory intent = order(10e6);
        (uint8 v, bytes32 r, bytes32 s) = sign(router, intent);
        if (mode == 0) intent.recipient = makeAddr("attacker");
        if (mode == 1) intent.amount += 1;
        if (mode == 2) intent.validAfter = 1;
        if (mode == 3) intent.validBefore += 1;
        if (mode == 4) intent.salt = bytes32(uint256(42));
        if (mode == 5) intent.payer = recipient;
        if (mode == 6) vm.chainId(block.chainid + 1);
        if (mode == 7) {
            router =
                new OpenTokenPurchaseRouter(IPaidMintToken(address(token)), usdc, address(vault));
        }
        vm.expectRevert("signature");
        router.buy(intent, v, r, s);
        assertEq(token.totalSupply(), 0);
        assertEq(usdc.balanceOf(payer), 1000e6);
    }

    function testFuzzBadOrders(uint8 raw) public {
        uint256 mode = bound(raw, 0, 6);
        OpenTokenPurchaseRouter.Order memory intent = order(1);
        if (mode == 0) intent.amount = 0;
        if (mode == 1) intent.payer = address(0);
        if (mode == 2) intent.payer = address(router);
        if (mode == 3) intent.recipient = address(0);
        if (mode == 4) intent.recipient = address(router);
        if (mode == 5) intent.recipient = address(token);
        if (mode == 6) intent.validBefore = 0;
        vm.expectRevert(OpenTokenPurchaseRouter.InvalidOrder.selector);
        router.buy(intent, 0, bytes32(0), bytes32(0));
    }

    function testFuzzCoreFailureRollsBackSignedAuthorization(uint8 raw) public {
        uint256 mode = bound(raw, 0, 2);
        OpenTokenPurchaseRouter.Order memory intent = order(10e6);
        (uint8 v, bytes32 r, bytes32 s) = sign(router, intent);
        bytes32 nonce = router.authorizationNonce(intent);
        if (mode == 0) vault.pause();
        if (mode == 1) usdc.setShortAuthorization(true);
        if (mode == 2) usdc.setFault(PaidOpenTokenUsdcFixture.Fault.ShortReceipt);
        vm.expectRevert();
        router.buy(intent, v, r, s);
        assertFalse(usdc.authorizationState(payer, nonce));
        assertFalse(router.purchased(nonce));
        assertEq(usdc.balanceOf(payer), 1000e6);
        assertEq(token.totalSupply(), 0);
        assertEq(usdc.allowance(address(router), address(minter)), 0);
    }

    function testExpiredSignatureCannotPayAndThenReceiveNothing() public {
        OpenTokenPurchaseRouter.Order memory intent = order(10e6);
        (uint8 v, bytes32 r, bytes32 s) = sign(router, intent);
        vm.warp(intent.validBefore);
        vm.expectRevert("authorization window or payee");
        router.buy(intent, v, r, s);
        assertFalse(router.purchased(router.authorizationNonce(intent)));
        assertEq(usdc.balanceOf(payer), 1000e6);
    }

    function testRejectInexactCoreDebit() public {
        RouterMintFaultFixture invalid =
            new RouterMintFaultFixture(IERC20(address(usdc)), address(token), address(vault));
        vm.prank(token.governanceTimelock());
        token.setMinter(address(minter), address(invalid));
        OpenTokenPurchaseRouter.Order memory intent = order(10e6);
        intent.minter = address(invalid);
        (uint8 v, bytes32 r, bytes32 s) = sign(router, intent);
        vm.expectRevert(OpenTokenPurchaseRouter.IncorrectPayment.selector);
        router.buy(intent, v, r, s);
        assertEq(usdc.balanceOf(payer), 1000e6);
    }

    function testFuzzInvalidBindings(uint8 raw) public {
        uint256 mode = bound(raw, 0, 6);
        address asset = mode == 0 ? recipient : address(token);
        address payment = mode == 1 ? recipient : mode == 2 ? asset : address(usdc);
        address treasuryAddress =
            mode == 3 ? address(0) : mode == 4 ? asset : mode == 5 ? payment : address(vault);
        if (mode == 6) asset = address(0);
        vm.expectRevert(OpenTokenPurchaseRouter.InvalidConfiguration.selector);
        new OpenTokenPurchaseRouter(IPaidMintToken(asset), IERC20(payment), treasuryAddress);
    }

    function testPaymentCannotReenterPurchase() public {
        OpenTokenPurchaseRouter.Order memory intent = order(10e6);
        (uint8 v, bytes32 r, bytes32 s) = sign(router, intent);
        usdc.setCallback(address(router), abi.encodeCall(router.buy, (intent, v, r, s)));
        router.buy(intent, v, r, s);
        assertEq(token.balanceOf(recipient), 10e6);
        assertEq(minter.mintedTotal(), 10e6);
    }

    function testOldOrderCannotPayAfterReplacementAndCannotRetargetSignature() public {
        OpenTokenPurchaseRouter.Order memory intent = order(10e6);
        (uint8 v, bytes32 r, bytes32 s) = sign(router, intent);
        OpenTokenMinter next = new OpenTokenMinter(
            OpenTokenMinter.Configuration(
                token, usdc, vault, token.governanceTimelock(), address(minter), 0
            )
        );
        vm.startPrank(token.governanceTimelock());
        minter.retire(address(next));
        token.setMinter(address(minter), address(next));
        next.initializeFromPredecessor();
        vm.stopPrank();
        vm.expectRevert(OpenTokenPurchaseRouter.InvalidOrder.selector);
        router.buy(intent, v, r, s);
        assertEq(usdc.balanceOf(payer), 1000e6);
        assertFalse(usdc.authorizationState(payer, router.authorizationNonce(intent)));
        intent.minter = address(next);
        vm.expectRevert("signature");
        router.buy(intent, v, r, s);
        (v, r, s) = sign(router, intent);
        router.buy(intent, v, r, s);
        assertEq(token.balanceOf(recipient), 10e6);
    }

    function testFuzzRouterRejectsActiveIssuerWithWrongBindingsBeforeTakingPayment(uint8 raw)
        public
    {
        OpenTokenPurchaseRouter.Order memory intent = order(1);
        uint256 mode = bound(raw, 0, 2);
        bytes memory getter = mode == 0
            ? abi.encodeWithSignature("token()")
            : mode == 1
                ? abi.encodeWithSignature("USDC()")
                : abi.encodeWithSignature("treasuryVault()");
        vm.mockCall(address(minter), getter, abi.encode(recipient));
        vm.expectRevert(OpenTokenPurchaseRouter.InvalidConfiguration.selector);
        router.buy(intent, 0, bytes32(0), bytes32(0));
        assertEq(usdc.balanceOf(payer), 1000e6);
    }
}
