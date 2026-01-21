
pragma solidity ^0.8.26;

import "../src/MockCoin.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import {SFLUVZapperv1, SFLUVZapperStorageInit} from "../src/SFLUVZapperv1.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import "@berachain/contracts/honey/IHoneyFactory.sol";
import { IBYUSD } from "../src/SFLUVZapperv1.sol";
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";




contract SFLUVZapperTest is Test {
    SFLUVv2 public testLUVCoin;
    SFLUVZapperv1 public testSFLUVZapper;
    IBYUSD public testBYUSD;

    address internal peon;
    address defaultAdmin = address(0x90496e23825aD0C8107d04671e6a27f30630Fc35);

    uint public oneEther = 1 ether; // TODO: elsewhere?

    ERC1967Proxy zapperproxy;

    error AccessControlUnauthorizedAccount(address account, bytes32 role);


    function setUp() public {

        string memory forkURL = vm.envString('FORK_URL');
        uint256 forkBlock = vm.envUint('FORK_BLOCK');


        vm.createSelectFork(forkURL, forkBlock);
        address sfluv = vm.envAddress('SFLUV_ADDRESS');
        address byusd = vm.envAddress("BYUSD_ADDRESS");
        address honey = vm.envAddress("HONEY_ADDRESS");
        address honeyToBYUSDPool = vm.envAddress("HONEY_BYUSD_POOL_ADDRESS");
        address byusdVault = vm.envAddress("BYUSD_VAULT_ADDRESS");
        testLUVCoin = SFLUVv2(sfluv);
        testBYUSD = IBYUSD(byusd);
        testSFLUVZapper = new SFLUVZapperv1();

        peon = makeAddr("peon");
        address honeyFactory = vm.envAddress("HONEY_FACTORY_ADDRESS");

        SFLUVZapperStorageInit memory testStorage = SFLUVZapperStorageInit(
            honeyFactory,
            sfluv,
            byusd,
            honey,
            honeyToBYUSDPool,
            byusdVault
        );

        zapperproxy = new ERC1967Proxy(address(testSFLUVZapper), abi.encodeCall(testSFLUVZapper.initialize, (defaultAdmin, testStorage)));
        testSFLUVZapper = SFLUVZapperv1(address(zapperproxy));
        vm.startPrank(defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ADMIN_ROLE(), defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.MINTER_ROLE(), address(testSFLUVZapper));
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), address(testSFLUVZapper));
        vm.stopPrank();
        }


    function testPermissionedWrappingFunctionality() public {
        // For easy decimal conversion
        uint byusdExp = 10**testBYUSD.decimals();
        uint sfluvExp = 10**testLUVCoin.decimals();
        // This should not change because we cut off the fork at a determined block, but just in case
        uint startingAdminLUVBalance = testLUVCoin.balanceOf(defaultAdmin);
        // Prank w/ BYUSD whale address
        vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
        // Transfer from BYUSD Whale acct to defaultAdmin
        testBYUSD.transfer(defaultAdmin, 1000 * byusdExp);
        //Prank w defaultAdmin account
        vm.startPrank(defaultAdmin);
        // defaultAdmin approves the SFLUV zapper to move 100 of its (defaultAdmin's) BYUSD
        testBYUSD.approve(address(testSFLUVZapper), 100 * byusdExp);
        //SFLUV zapper takes 50 BYUSD to be converted to SFLUV
        testSFLUVZapper.zapIn(50 * byusdExp);
        vm.stopPrank();
        // assert that defaultAdmin has 50 sfluv (50 more than it had before) and 950 byusd
        assert(testLUVCoin.balanceOf(defaultAdmin) == ((50 * sfluvExp) + startingAdminLUVBalance));
        assert(testBYUSD.balanceOf(defaultAdmin) == 950 * byusdExp);
    }

    function testUnpermissionedWrappingFunctionality() public {
        // For easy decimal conversion
        uint byusdExp = 10**testBYUSD.decimals();
        uint sfluvExp = 10**testLUVCoin.decimals();
        // Prank w/ BYUSD whale address
        vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
        // Transfer from BYUSD Whale acct to peon
        testBYUSD.transfer(peon, 1000 * byusdExp);
        // Prank w peon
        vm.startPrank(peon);
        // peon approves the SFLUV zapper to move 100 of its (peon's) BYUSD
        testBYUSD.approve(address(testSFLUVZapper), 100 * byusdExp);
        bytes32 myRole = testSFLUVZapper.MINTER_ROLE();
        //SFLUV zapper takes 50 BYUSD to be converted to SFLUV
        vm.expectRevert(abi.encodeWithSelector(
        AccessControlUnauthorizedAccount.selector,
        peon,
        myRole
        ));
        testSFLUVZapper.zapIn(50 * byusdExp);
    }

    function testUnwrappingFunctionality() public {
       // For easy decimal conversion
        uint byusdExp = 10**testBYUSD.decimals();
        uint sfluvExp = 10**testLUVCoin.decimals();
        uint honeyCharge = 5 * byusdExp;
        uint denominator = 10000;
        uint honeyFee = honeyCharge / denominator;
        uint conversionAmount = 25;
        uint honeyRake = honeyFee * conversionAmount;
        // This should not change because we cut off the fork at a determined block, but just in case
        uint startingAdminLUVBalance = testLUVCoin.balanceOf(defaultAdmin);
        uint startingAdminBYUSDBalance = testBYUSD.balanceOf(defaultAdmin);
        // Prank w defaultAdmin account
        vm.startPrank(defaultAdmin);
        // defaultAdmin approves the SFLUV zapper to move 100 of its (defaultAdmin's) SFLUV
        testLUVCoin.approve(address(testSFLUVZapper), 100 * sfluvExp);
        //SFLUV zapper takes 25 SFLUV to be converted to BYUSD
        testSFLUVZapper.zapOut(conversionAmount * sfluvExp);
        vm.stopPrank();
        // assert that defaultAdmin has 25 less SFLUV that it started with, and 975 byusd
        assert(testLUVCoin.balanceOf(defaultAdmin) == (startingAdminLUVBalance - (conversionAmount * sfluvExp)));
        assert(testBYUSD.balanceOf(defaultAdmin) == ((conversionAmount * byusdExp) - (honeyRake)));
    }

    function testUnpermissionedUnwrappingFunctionality() public {
       // For easy decimal conversion
        uint byusdExp = 10**testBYUSD.decimals();
        uint sfluvExp = 10**testLUVCoin.decimals();
        // Prank w peon
        vm.startPrank(peon);
        // peon approves the SFLUV zapper to move 100 of its (peons) SFLUV
        testLUVCoin.approve(address(testSFLUVZapper), 100 * sfluvExp);
        bytes32 myRole = testSFLUVZapper.REDEEMER_ROLE();
        //SFLUV zapper takes 50 BYUSD to be converted to SFLUV
        vm.expectRevert(abi.encodeWithSelector(
        AccessControlUnauthorizedAccount.selector,
        peon,
        myRole
        ));
        testSFLUVZapper.zapOut(50 * byusdExp);
        vm.stopPrank();
    }

    function testUnwrapSwapAndBridge() public {
    // ----------------------------
    // Setup decimal helpers
    // ----------------------------
    uint256 byusdExp = 10**testBYUSD.decimals();
    uint256 sfluvExp = 10**testLUVCoin.decimals();

    // Send some BYUSD to defaultAdmin from whale
    vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
    testBYUSD.transfer(defaultAdmin, 1000 * byusdExp);

    // Approve zapper
    vm.startPrank(defaultAdmin);
    testBYUSD.approve(address(testSFLUVZapper), 100 * byusdExp);

    // Wrap 100 BYUSD into SFLUV first
    testSFLUVZapper.zapIn(100 * byusdExp);

    uint256 startingLUVBalance = testLUVCoin.balanceOf(defaultAdmin);
    console.log("Starting SFLUV balance:", startingLUVBalance);

    // ----------------------------
    // Construct SendParam
    // ----------------------------
    SendParam memory lzParam = SendParam({
    dstEid: 30101,
    to: bytes32(uint256(uint160(address(defaultAdmin)))), // spoofed ETH address
    amountLD: 50 * byusdExp,
    minAmountLD: 0,
    extraOptions: "",
    composeMsg: "",
    oftCmd: ""
});

    // ----------------------------
    // Call unwrap/swap/bridge
    // ----------------------------
    (MessagingReceipt memory mReceipt, OFTReceipt memory oReceipt) =
        testSFLUVZapper.unwrapSwapAndBridge(lzParam);

    // ----------------------------
    // Logging receipts for inspection
    // ----------------------------
    console.log("MessagingReceipt:");
    console.log(" dstEid:", mReceipt.dstEid);
    console.log(" srcEid:", mReceipt.srcEid);
    console.log(" nonce:", mReceipt.nonce);
    console.log(" success:", mReceipt.success ? 1 : 0);

    console.log("OFTReceipt:");
    console.log(" amount:", oReceipt.amount);
    console.log(" fee:", oReceipt.fee);
    console.log(" success:", oReceipt.success ? 1 : 0);

    // ----------------------------
    // Verify SFLUV balance decreased
    // ----------------------------
    uint256 endingLUVBalance = testLUVCoin.balanceOf(defaultAdmin);
    console.log("Ending SFLUV balance:", endingLUVBalance);
    assert(endingLUVBalance < startingLUVBalance);

    vm.stopPrank();
}


    }
