pragma solidity ^0.8.26;

import "../src/MockCoin.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import {SFLUVUSDCeZapper, SFLUVUSDCeZapperStorageInit} from "../src/SFLUVUSDCeZapper.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "openzeppelin-foundry-upgrades/Upgrades.sol";
import "@berachain/contracts/honey/IHoneyFactory.sol";
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { Honey } from "lib/bera-contracts/src/honey/Honey.sol";
import { ILiquidityPool} from "../src/ILiquidityPool.sol";
import { HoneyFactory } from "lib/bera-contracts/src/honey/HoneyFactory.sol";

interface IUSDCe {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface ICollateralVaultView {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function paused() external view returns (bool);
}

contract SFLUVUSDCeZapperTest is Test {
    SFLUVv2 public testLUVCoin;
    SFLUVUSDCeZapper public testZapper;
    IUSDCe public testUSDCe;
    Honey public honeyToken;
    ILiquidityPool public liquidityPool;
    HoneyFactory public testHoneyFactory;
    address public usdcVault;

    address internal peon;
    address vitEth = address(0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045);
    address defaultAdmin = address(0x90496e23825aD0C8107d04671e6a27f30630Fc35);

    uint public oneEther = 1 ether;

    ERC1967Proxy zapperproxy;

    error AccessControlUnauthorizedAccount(address account, bytes32 role);

    function setUp() public {
        string memory forkURL = vm.envString("FORK_URL");
        uint256 forkBlock = vm.envUint("FORK_BLOCK");
        vm.createSelectFork(forkURL, forkBlock);

        address sfluv = vm.envAddress("SFLUV_ADDRESS");
        address honey = vm.envAddress("HONEY_ADDRESS");
        address usdc = vm.envAddress("USDC_E_ADDRESS");
        address usdcAdapter = vm.envAddress("USDC_E_ADAPTER_ADDRESS");
        address usdcVaultAddress = vm.envAddress("USDC_E_VAULT_ADDRESS");
        address honeyToUSDCPool = vm.envAddress("HONEY_USDC_POOL_ADDRESS");
        address honeyFactoryAddress = vm.envAddress("HONEY_FACTORY_ADDRESS");
        uint32 usdcDstEid = uint32(vm.envUint("USDC_DST_EID"));

        peon = makeAddr("peon");

        testLUVCoin = SFLUVv2(sfluv);
        testUSDCe = IUSDCe(usdc);
        liquidityPool = ILiquidityPool(honeyToUSDCPool);
        testHoneyFactory = HoneyFactory(honeyFactoryAddress);
        honeyToken = Honey(honey);
        usdcVault = usdcVaultAddress;

        testZapper = new SFLUVUSDCeZapper();

        SFLUVUSDCeZapperStorageInit memory testStorage = SFLUVUSDCeZapperStorageInit(
            honeyFactoryAddress,
            sfluv,
            honey,
            usdc,
            usdcAdapter,
            usdcVaultAddress,
            honeyToUSDCPool,
            usdcDstEid
        );

        zapperproxy = new ERC1967Proxy(address(testZapper), abi.encodeCall(testZapper.initialize, (defaultAdmin, testStorage)));
        testZapper = SFLUVUSDCeZapper(payable(zapperproxy));

        vm.startPrank(defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ADMIN_ROLE(), defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), address(testZapper));
        vm.stopPrank();
    }

    function testUnpermissionedUnwrappingFunctionality() public {
        uint sfluvExp = 10**testLUVCoin.decimals();

        vm.startPrank(peon);
        testLUVCoin.approve(address(testZapper), 100 * sfluvExp);
        bytes32 myRole = testZapper.REDEEMER_ROLE();
        vm.expectRevert(abi.encodeWithSelector(
            AccessControlUnauthorizedAccount.selector,
            peon,
            myRole
        ));
        testZapper.unwrapSwapAndBridgeUSDCe(50 * sfluvExp, peon);
        vm.stopPrank();
    }

    function testUnwrapRedeemAndBridgeUSDCe() public {
        uint256 usdcExp = 10**testUSDCe.decimals();
        uint256 sfluvExp = 10**testLUVCoin.decimals();

        // Simulate zap-in via USDC.e to seed the Honey USDC.e vault and mint SFLUV
        vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
        testUSDCe.transfer(defaultAdmin, 100 * usdcExp);

        vm.startPrank(defaultAdmin);
        testUSDCe.approve(address(testHoneyFactory), 50 * usdcExp);
        uint256 honeyAmount = testHoneyFactory.mint(address(testUSDCe), 50 * usdcExp, defaultAdmin, false);
        honeyToken.approve(address(testLUVCoin), honeyAmount);
        testLUVCoin.depositFor(defaultAdmin, honeyAmount);
        vm.stopPrank();

        // Send some USDC.e to the zapper from whale
        vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
        testUSDCe.transfer(address(testZapper), 100 * usdcExp);

        // Fund zapper with BERA for messaging fees
        vm.deal(address(testZapper), 100 * sfluvExp);

        vm.startPrank(defaultAdmin);
        testLUVCoin.approve(address(testZapper), 100 * sfluvExp);

        uint256 originalBalance = testLUVCoin.balanceOf(address(defaultAdmin));

        // Call unwrap/swap/bridge - honey is funded with enough USDC.e so the liquidity pool is not used
        (MessagingReceipt memory mReceipt, OFTReceipt memory oReceipt) =
            testZapper.unwrapSwapAndBridgeUSDCe(50 * sfluvExp, vitEth);

        vm.stopPrank();

        console.log("MessagingReceipt:");
        console.logBytes32(mReceipt.guid);
        console.log(" nonce:", mReceipt.nonce);
        console.log(" messaging fee - nativeFee:", mReceipt.fee.nativeFee);
        console.log(" messaging fee - lzTokenFee:", mReceipt.fee.lzTokenFee);

        console.log("OFTReceipt:");
        console.log(" amountSent:", oReceipt.amountSentLD);
        console.log(" amountRecieved:", oReceipt.amountReceivedLD);
        assert(oReceipt.amountSentLD == 50 * usdcExp);
        assert(oReceipt.amountReceivedLD >= (50 * usdcExp * 95 / 100));
        assert(oReceipt.amountReceivedLD >= (50 * usdcExp * 95 / 100));

        assert(testLUVCoin.balanceOf(defaultAdmin) == originalBalance - (50 * sfluvExp));
    }

    function testUnwrapSplitRedeemBridgeUSDCe() public {
        string memory forkURL = vm.envString("FORK_URL");
        uint256 currentBlockFork = 16654671;
        vm.createSelectFork(forkURL, currentBlockFork);

        address sfluv = vm.envAddress("SFLUV_ADDRESS");
        address honey = vm.envAddress("HONEY_ADDRESS");
        address usdc = vm.envAddress("USDC_E_ADDRESS");
        address usdcAdapter = vm.envAddress("USDC_E_ADAPTER_ADDRESS");
        address usdcVaultAddress = vm.envAddress("USDC_E_VAULT_ADDRESS");
        address honeyToUSDCPool = vm.envAddress("HONEY_USDC_POOL_ADDRESS");
        address honeyFactoryAddress = vm.envAddress("HONEY_FACTORY_ADDRESS");
        uint32 usdcDstEid = uint32(vm.envUint("USDC_DST_EID"));
        address sfluvWhale = address(0x234D25189D22947C3B0a39959eEEfAc36c022BE0);

        SFLUVUSDCeZapperStorageInit memory testStorage = SFLUVUSDCeZapperStorageInit(
            honeyFactoryAddress,
            sfluv,
            honey,
            usdc,
            usdcAdapter,
            usdcVaultAddress,
            honeyToUSDCPool,
            usdcDstEid
        );

        testZapper = new SFLUVUSDCeZapper();
        zapperproxy = new ERC1967Proxy(address(testZapper), abi.encodeCall(testZapper.initialize, (defaultAdmin, testStorage)));
        testZapper = SFLUVUSDCeZapper(payable(zapperproxy));
        testLUVCoin = SFLUVv2(sfluv);
        testUSDCe = IUSDCe(usdc);
        testHoneyFactory = HoneyFactory(honeyFactoryAddress);
        usdcVault = usdcVaultAddress;

        vm.startPrank(defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ADMIN_ROLE(), defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), address(testZapper));
        vm.stopPrank();

        uint256 usdcExp = 10**testUSDCe.decimals();
        uint256 sfluvExp = 10**testLUVCoin.decimals();

        // Simulate zap-in via USDC.e so Honey vault has a bit over 50 USDC.e
        vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
        testUSDCe.transfer(defaultAdmin, 100 * usdcExp);

        vm.startPrank(defaultAdmin);
        testUSDCe.approve(address(testHoneyFactory), 50 * usdcExp);
        uint256 honeyAmount = testHoneyFactory.mint(address(testUSDCe), 50 * usdcExp, defaultAdmin, false);
        honeyToken.approve(address(testLUVCoin), honeyAmount);
        testLUVCoin.depositFor(defaultAdmin, honeyAmount);
        vm.stopPrank();

        // Send some USDC.e to the zapper from whale
        vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
        testUSDCe.transfer(address(testZapper), 100 * usdcExp);

        vm.deal(address(testZapper), 100 * sfluvExp);

        uint256 startingLUVBalance = testLUVCoin.balanceOf(defaultAdmin);

        vm.startPrank(sfluvWhale);
        testLUVCoin.transfer(defaultAdmin, 50 * sfluvExp);
        vm.stopPrank();

        vm.startPrank(defaultAdmin);
        testLUVCoin.approve(address(testZapper), 50 * sfluvExp);

        (MessagingReceipt memory mReceipt, OFTReceipt memory oReceipt) =
            testZapper.unwrapSwapAndBridgeUSDCe(50 * sfluvExp, vitEth);
        vm.stopPrank();

        console.log("MessagingReceipt:");
        console.logBytes32(mReceipt.guid);
        console.log(" nonce:", mReceipt.nonce);
        console.log(" messaging fee - nativeFee:", mReceipt.fee.nativeFee);
        console.log(" messaging fee - lzTokenFee:", mReceipt.fee.lzTokenFee);

        console.log("OFTReceipt:");
        console.log(" amountSent:", oReceipt.amountSentLD);
        console.log(" amountRecieved:", oReceipt.amountReceivedLD);
        assert(oReceipt.amountSentLD == 50 * usdcExp);

        uint256 endingLUVBalance = testLUVCoin.balanceOf(defaultAdmin);
        assert(endingLUVBalance == startingLUVBalance);
    }

    function testLiquidityPool() public {
        vm.startPrank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
        honeyToken.transfer(address(testZapper), 1000 * 1e18);
        vm.stopPrank();

        assert(honeyToken.balanceOf(address(testZapper)) == 1000 * 1e18);

        (uint160 sqrtPriceX96,,,,,,) = liquidityPool.slot0();

        uint256 NUM = 1_025_978_352;
        uint256 DEN = 1_000_000_000;

        uint256 sqrtPriceLimitX96 = uint256(
            (uint256(sqrtPriceX96) * NUM) / DEN
        );

        vm.startPrank(address(testZapper));
        liquidityPool.swap(
            address(testZapper),
            false,
            int256(500 * 1e18),
            uint160(sqrtPriceLimitX96),
            ""
        );
        vm.stopPrank();

        assert(testUSDCe.balanceOf(address(testZapper)) > 490000000);
        assert(honeyToken.balanceOf(address(testZapper)) == 500000000000000000000);
    }
}
