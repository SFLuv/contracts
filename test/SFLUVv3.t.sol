// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

import {MockCoin} from "../src/MockCoin.sol";
import {SFLUVv3} from "../src/SFLUVv3.sol";
import {ERC3009Upgradeable} from "../src/ERC3009Upgradeable.sol";

/// @dev Minimal EIP-1271 wallet that accepts a single hardcoded digest as valid.
contract MockERC1271Wallet is IERC1271 {
    bytes32 public approvedDigest;
    bytes4 internal constant MAGIC = 0x1626ba7e;

    function approve(bytes32 digest) external {
        approvedDigest = digest;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view returns (bytes4) {
        return hash == approvedDigest ? MAGIC : bytes4(0xffffffff);
    }
}

contract SFLUVv3Test is Test {
    MockCoin internal mockCoin;
    SFLUVv3 internal sfluv;

    address internal gov;
    address internal alicePk; // signer
    uint256 internal aliceKey;
    address internal bob;
    address internal relayer;

    bytes32 internal constant TRANSFER_TYPEHASH =
        keccak256(
            "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );
    bytes32 internal constant RECEIVE_TYPEHASH =
        keccak256(
            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    function setUp() public {
        // Use a deterministic, non-zero timestamp so validAfter/validBefore math is sane.
        vm.warp(1_700_000_000);

        mockCoin = new MockCoin();
        SFLUVv3 impl = new SFLUVv3();

        gov = makeAddr("gov");
        (alicePk, aliceKey) = makeAddrAndKey("alice");
        bob = makeAddr("bob");
        relayer = makeAddr("relayer");

        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(impl.initialize, (gov, mockCoin))
        );
        sfluv = SFLUVv3(address(proxy));

        // Grant minter role and fund Alice with 1000 SFLUV.
        vm.startPrank(gov);
        sfluv.grantRole(sfluv.MINTER_ADMIN_ROLE(), gov);
        sfluv.grantRole(sfluv.MINTER_ROLE(), gov);
        vm.stopPrank();

        mockCoin.mint(gov, 1000 ether);
        vm.startPrank(gov);
        mockCoin.approve(address(sfluv), 1000 ether);
        sfluv.depositFor(alicePk, 1000 ether);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _digestTransfer(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce));
        return _toTypedDataHash(structHash);
    }

    function _toTypedDataHash(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = sfluv.DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // ---- happy paths ----

    function testTransferWithAuthorization() public {
        uint256 value = 100 ether;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-1");

        bytes32 digest = _digestTransfer(TRANSFER_TYPEHASH, alicePk, bob, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        // Anyone can submit (this is the documented front-running surface).
        vm.prank(relayer);
        sfluv.transferWithAuthorization(alicePk, bob, value, validAfter, validBefore, nonce, v, r, s);

        assertEq(sfluv.balanceOf(bob), value, "bob got tokens");
        assertEq(sfluv.balanceOf(alicePk), 1000 ether - value, "alice debited");
        assertTrue(sfluv.authorizationState(alicePk, nonce), "nonce burned");
    }

    function testReceiveWithAuthorizationRequiresPayeeCaller() public {
        uint256 value = 50 ether;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("nonce-receive");

        bytes32 digest = _digestTransfer(RECEIVE_TYPEHASH, alicePk, bob, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        // Relayer can't front-run this one.
        vm.prank(relayer);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009CallerNotPayee.selector, relayer, bob)
        );
        sfluv.receiveWithAuthorization(alicePk, bob, value, validAfter, validBefore, nonce, v, r, s);

        // Bob can.
        vm.prank(bob);
        sfluv.receiveWithAuthorization(alicePk, bob, value, validAfter, validBefore, nonce, v, r, s);
        assertEq(sfluv.balanceOf(bob), value);
    }

    function testCancelAuthorization() public {
        bytes32 nonce = keccak256("nonce-cancel");

        _cancelNonce(nonce);
        assertTrue(sfluv.authorizationState(alicePk, nonce));

        // Now try to use that nonce — should fail.
        _expectCanceledNonceReverts(nonce);
    }

    function _cancelNonce(bytes32 nonce) private {
        bytes32 structHash = keccak256(abi.encode(CANCEL_TYPEHASH, alicePk, nonce));
        bytes32 digest = _toTypedDataHash(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        vm.prank(relayer);
        sfluv.cancelAuthorization(alicePk, nonce, v, r, s);
    }

    function _expectCanceledNonceReverts(bytes32 nonce) private {
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 digest = _digestTransfer(TRANSFER_TYPEHASH, alicePk, bob, 1 ether, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009AuthorizationUsed.selector, alicePk, nonce)
        );
        sfluv.transferWithAuthorization(alicePk, bob, 1 ether, validAfter, validBefore, nonce, v, r, s);
    }

    // ---- error paths ----

    function testRevertWhenNonceReused() public {
        uint256 value = 1 ether;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("reuse");

        bytes32 digest = _digestTransfer(TRANSFER_TYPEHASH, alicePk, bob, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        sfluv.transferWithAuthorization(alicePk, bob, value, validAfter, validBefore, nonce, v, r, s);

        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009AuthorizationUsed.selector, alicePk, nonce)
        );
        sfluv.transferWithAuthorization(alicePk, bob, value, validAfter, validBefore, nonce, v, r, s);
    }

    function testRevertWhenNotYetValid() public {
        uint256 value = 1 ether;
        uint256 validAfter = block.timestamp + 10 minutes;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("future");

        bytes32 digest = _digestTransfer(TRANSFER_TYPEHASH, alicePk, bob, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009AuthorizationNotYetValid.selector, validAfter)
        );
        sfluv.transferWithAuthorization(alicePk, bob, value, validAfter, validBefore, nonce, v, r, s);
    }

    function testRevertWhenExpired() public {
        uint256 value = 1 ether;
        uint256 validAfter = block.timestamp - 1 hours;
        uint256 validBefore = block.timestamp - 10 minutes;
        bytes32 nonce = keccak256("expired");

        bytes32 digest = _digestTransfer(TRANSFER_TYPEHASH, alicePk, bob, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);

        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009AuthorizationExpired.selector, validBefore)
        );
        sfluv.transferWithAuthorization(alicePk, bob, value, validAfter, validBefore, nonce, v, r, s);
    }

    function testRevertOnBadSigner() public {
        uint256 value = 1 ether;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("bad-signer");

        bytes32 digest = _digestTransfer(TRANSFER_TYPEHASH, alicePk, bob, value, validAfter, validBefore, nonce);
        // Sign with a key that is not alice's.
        (, uint256 mallory) = makeAddrAndKey("mallory");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(mallory, digest);

        vm.expectRevert(
            abi.encodeWithSelector(ERC3009Upgradeable.ERC3009InvalidSignature.selector, alicePk)
        );
        sfluv.transferWithAuthorization(alicePk, bob, value, validAfter, validBefore, nonce, v, r, s);
    }

    // ---- EIP-1271 (smart-wallet) path ----

    function testEIP1271TransferWithAuthorization() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet();

        // Fund the wallet with SFLUV by minting to it through governance.
        mockCoin.mint(gov, 100 ether);
        vm.startPrank(gov);
        mockCoin.approve(address(sfluv), 100 ether);
        sfluv.depositFor(address(wallet), 100 ether);
        vm.stopPrank();

        uint256 value = 10 ether;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("1271");

        bytes32 digest = _digestTransfer(TRANSFER_TYPEHASH, address(wallet), bob, value, validAfter, validBefore, nonce);
        wallet.approve(digest);

        // Use the bytes-signature overload; the bytes payload itself doesn't matter for the mock.
        bytes memory sig = hex"";
        vm.prank(relayer);
        sfluv.transferWithAuthorization(address(wallet), bob, value, validAfter, validBefore, nonce, sig);

        assertEq(sfluv.balanceOf(bob), value);
    }
}
