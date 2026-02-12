
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
import "forge-std/console.sol";
import { Honey } from "lib/bera-contracts/src/honey/Honey.sol";
import { ILiquidityPool} from "../src/ILiquidityPool.sol";
import { HoneyFactory } from "lib/bera-contracts/src/honey/HoneyFactory.sol";



interface IWBERA {
    // ERC20 standard functions you might need
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);

    // unwrap WBERA to native BERA
    function withdraw(uint256 amount) external;

    // optional: wrap BERA into WBERA
    function deposit() external payable;
}


contract SFLUVZapperTest is Test {
    SFLUVv2 public testLUVCoin;
    SFLUVZapperv1 public testSFLUVZapper;
    IBYUSD public testBYUSD;
    IWBERA public wbera;
    Honey public honeyToken;
    ILiquidityPool public liquidityPool;
    HoneyFactory public testHoneyFactory;

    address internal peon;
    address vitEth = address(0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045);
    address defaultAdmin = address(0x90496e23825aD0C8107d04671e6a27f30630Fc35);


    uint public oneEther = 1 ether; // TODO: elsewhere?

    ERC1967Proxy zapperproxy;

    error AccessControlUnauthorizedAccount(address account, bytes32 role);


function setUp() public {
    // Create fork using an old fork block with a heavily funded HONEY pool
    string memory forkURL = vm.envString('FORK_URL');
    uint256 forkBlock = vm.envUint('FORK_BLOCK');
    vm.createSelectFork(forkURL, forkBlock);


    // Pull SFLUV Zapper storage variables from environment and set up other necessary addresses
    address sfluv = vm.envAddress('SFLUV_ADDRESS');
    address byusd = vm.envAddress("BYUSD_ADDRESS");
    address honey = vm.envAddress("HONEY_ADDRESS");
    address honeyToBYUSDPool = vm.envAddress("HONEY_BYUSD_POOL_ADDRESS");
    address byusdVault = vm.envAddress("BYUSD_VAULT_ADDRESS");
    address wrappedNative = vm.envAddress("WRAPPED_NATIVE_ADDRESS");
    address honeyFactoryAddress = vm.envAddress("HONEY_FACTORY_ADDRESS");
    peon = makeAddr("peon");

    // Create contract instances out of addresses
    wbera = IWBERA(wrappedNative);
    testLUVCoin = SFLUVv2(sfluv);
    testBYUSD = IBYUSD(byusd);
    liquidityPool = ILiquidityPool(honeyToBYUSDPool);
    testHoneyFactory = HoneyFactory(honeyFactoryAddress);
    honeyToken = Honey(honey);

    // Create new Zapper instance
    testSFLUVZapper = new SFLUVZapperv1();

    // Set up storage struct by calling initialize using addresses from environment variables
    SFLUVZapperStorageInit memory testStorage = SFLUVZapperStorageInit(
        honeyFactoryAddress,
        sfluv,
        byusd,
        honey,
        honeyToBYUSDPool,
        byusdVault
    );

    // Deploy proxy pointing to zapper implementation
    zapperproxy = new ERC1967Proxy(address(testSFLUVZapper), abi.encodeCall(testSFLUVZapper.initialize, (defaultAdmin, testStorage)));

    // Cast proxy address to zapper interface and make it payable
    testSFLUVZapper = SFLUVZapperv1(payable(zapperproxy));

    // Prank from defaultAdmin to give necessary permissions
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

function testUnwrapRedeemAndBridge() public {

    // Setup decimal helpers
    uint256 byusdExp = 10**testBYUSD.decimals();
    uint256 sfluvExp = 10**testLUVCoin.decimals();

    // Send some BYUSD to defaultAdmin from whale
    vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
    testBYUSD.transfer(defaultAdmin, 1000 * byusdExp);

    // Send some BYUSD to SFLuvZapper from whale
    vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
    testBYUSD.transfer(address(testSFLUVZapper), 100 * byusdExp);

    // Fund zapper and BYUSD contract with BERA for messaging fees
    vm.deal(address(testSFLUVZapper), 100 * sfluvExp);
    vm.deal(address(testBYUSD), 100 * sfluvExp);

    // Default Admin approves zapper to move $100 worth of BYUSD and SFLUV
    vm.startPrank(defaultAdmin);
    testBYUSD.approve(address(testSFLUVZapper), 100 * byusdExp);
    testLUVCoin.approve(address(testSFLUVZapper), 100 * sfluvExp);



    // Record original SFLUV balance then wrap 50 BYUSD into SFLUV
    uint256 orininalBalance = testLUVCoin.balanceOf(address(defaultAdmin));
    testSFLUVZapper.zapIn(50 * byusdExp);

    //Check that that the default admin has correct SFLUV balance
    assert(testLUVCoin.balanceOf(defaultAdmin) == (50 * sfluvExp) + orininalBalance);


    // Call unwrap/swap/bridge - honey is funded with enough BYUSD in this test so the liquidity pool is not used
    (MessagingReceipt memory mReceipt, OFTReceipt memory oReceipt) =
        testSFLUVZapper.unwrapSwapAndBridge(50 * sfluvExp, vitEth);

    vm.stopPrank();

    // Logging MessagingReceipt for inspection
    console.log("MessagingReceipt:");
    console.logBytes32(mReceipt.guid);
    console.log(" nonce:", mReceipt.nonce);
    console.log(" messaging fee - nativeFee:", mReceipt.fee.nativeFee);
    console.log(" messaging fee - lzTokenFee:", mReceipt.fee.lzTokenFee);

    // Logging OFTReceipt for inspection, assert that the amount sent is correct
    console.log("OFTReceipt:");
    console.log(" amountSent:", oReceipt.amountSentLD);
    console.log(" amountRecieved:", oReceipt.amountReceivedLD);
    assert(oReceipt.amountSentLD == 50 * byusdExp);


       // Verify SFLUV is now back to original balance
   assert(testLUVCoin.balanceOf(defaultAdmin) == orininalBalance);
}

function testUnwrapBasketModeUsesPoolSwapOnly() public {
    uint256 byusdExp = 10**testBYUSD.decimals();
    uint256 sfluvExp = 10**testLUVCoin.decimals();

    vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
    testBYUSD.transfer(defaultAdmin, 1000 * byusdExp);

    vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
    testBYUSD.transfer(address(testSFLUVZapper), 100 * byusdExp);

    vm.deal(address(testSFLUVZapper), 100 * sfluvExp);
    vm.deal(address(testBYUSD), 100 * sfluvExp);

    vm.startPrank(defaultAdmin);
    testBYUSD.approve(address(testSFLUVZapper), 100 * byusdExp);
    testLUVCoin.approve(address(testSFLUVZapper), 100 * sfluvExp);

    uint256 originalBalance = testLUVCoin.balanceOf(address(defaultAdmin));
    testSFLUVZapper.zapIn(50 * byusdExp);

    vm.mockCall(
        address(testHoneyFactory),
        abi.encodeWithSelector(HoneyFactory.isBasketModeEnabled.selector, false),
        abi.encode(true)
    );
    vm.mockCallRevert(
        address(testHoneyFactory),
        abi.encodeWithSelector(IHoneyFactory.redeem.selector),
        "redeem path should be skipped in basket mode"
    );

    (, OFTReceipt memory oReceipt) = testSFLUVZapper.unwrapSwapAndBridge(50 * sfluvExp, vitEth);
    vm.stopPrank();

    assert(oReceipt.amountSentLD == 50 * byusdExp);
    assert(testLUVCoin.balanceOf(defaultAdmin) == originalBalance);
}

function testUnwrapSplitRedeemBridge() public {

    // Switch to fork where HONEY is barely funded with BYUSD
    string memory forkURL = vm.envString('FORK_URL');
    uint256 currentBlockFork = vm.envUint('UP_TO_DATE_FORK_BLOCK');
    vm.createSelectFork(forkURL, currentBlockFork);

    // Setup SFLUVZapper, same as in setUp(), this is necesary because we switched forks and the new fork doesn't have the zapper deployed yet
    address sfluv = vm.envAddress('SFLUV_ADDRESS');
    address byusd = vm.envAddress("BYUSD_ADDRESS");
    address honey = vm.envAddress("HONEY_ADDRESS");
    address honeyToBYUSDPool = vm.envAddress("HONEY_BYUSD_POOL_ADDRESS");
    address byusdVault = vm.envAddress("BYUSD_VAULT_ADDRESS");
    address honeyFactory = vm.envAddress("HONEY_FACTORY_ADDRESS");
    address sfluvWhale = address(0x234D25189D22947C3B0a39959eEEfAc36c022BE0);

    SFLUVZapperStorageInit memory testStorage = SFLUVZapperStorageInit(
            honeyFactory,
            sfluv,
            byusd,
            honey,
            honeyToBYUSDPool,
            byusdVault
        );

    testSFLUVZapper = new SFLUVZapperv1();
    zapperproxy = new ERC1967Proxy(address(testSFLUVZapper), abi.encodeCall(testSFLUVZapper.initialize, (defaultAdmin, testStorage)));
    testSFLUVZapper = SFLUVZapperv1(payable(zapperproxy));
    vm.startPrank(defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ADMIN_ROLE(), defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), defaultAdmin);
        testLUVCoin.grantRole(testLUVCoin.MINTER_ROLE(), address(testSFLUVZapper));
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), address(testSFLUVZapper));
    vm.stopPrank();

    // Setup decimal helpers
    uint256 byusdExp = 10**testBYUSD.decimals();
    uint256 sfluvExp = 10**testLUVCoin.decimals();

    // Send some BYUSD to defaultAdmin from whale
    vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
    testBYUSD.transfer(defaultAdmin, 1000 * byusdExp);

    // Send some BYUSD to SFLuvZapper from whale
    vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
    testBYUSD.transfer(address(testSFLUVZapper), 100 * byusdExp);

    // Fund zapper and BYUSD contract with BERA for messaging fees
    vm.deal(address(testSFLUVZapper), 100 * sfluvExp);
    vm.deal(address(testBYUSD), 100 * sfluvExp);

    // Record starting SFLUV balance
    uint256 startingLUVBalance = testLUVCoin.balanceOf(defaultAdmin);

    // Transfer 100 SFLUV from whale to defaultAdmin
    vm.startPrank(sfluvWhale);
    testLUVCoin.transfer(defaultAdmin, 100 * sfluvExp);
    vm.stopPrank();

    // Approve zapper to move defaultAdmin's BYUSD and SFLUV
    vm.startPrank(defaultAdmin);
    testBYUSD.approve(address(testSFLUVZapper), 100 * byusdExp);
    testLUVCoin.approve(address(testSFLUVZapper), 100 * sfluvExp);

    // Wrap 50 BYUSD into SFLUV first, and assert that the BYUSD vault balance is now just barely above 50
    uint byusdAmountToWrap = 50 * byusdExp;
    uint amountPlusBuffer = byusdAmountToWrap + 3e6; // adding 5 BYUSD buffer
    testSFLUVZapper.zapIn(byusdAmountToWrap);
    assert(testBYUSD.balanceOf(vm.envAddress("BYUSD_VAULT_ADDRESS")) <= amountPlusBuffer);

    // Assert that defaultAdmin has at least 149 extra SFLUV now (this accounts for a 1% at max ZapIn slippage)
    assert(testLUVCoin.balanceOf(defaultAdmin) >= (149 * sfluvExp) + startingLUVBalance);

    // Reset starting LUV balance to current balance
    startingLUVBalance = testLUVCoin.balanceOf(defaultAdmin);

    // Call unwrap/swap/bridge - honey is underfunded with BYUSD in this test so the liquidity pool is used
    (MessagingReceipt memory mReceipt, OFTReceipt memory oReceipt) =
        testSFLUVZapper.unwrapSwapAndBridge(100 * sfluvExp, vitEth);
    vm.stopPrank();


    // Logging receipts for inspection
    console.log("MessagingReceipt:");
    console.logBytes32(mReceipt.guid);
    console.log(" nonce:", mReceipt.nonce);
    console.log(" messaging fee - nativeFee:", mReceipt.fee.nativeFee);
    console.log(" messaging fee - lzTokenFee:", mReceipt.fee.lzTokenFee);

    // Logging OFTReceipt for inspection, assert that the amount sent is correct
    console.log("OFTReceipt:");
    console.log(" amountSent:", oReceipt.amountSentLD);
    console.log(" amountRecieved:", oReceipt.amountReceivedLD);
    assert(oReceipt.amountSentLD == 100 * byusdExp);

    // Verify SFLUV balance decreased by 100
    uint256 endingLUVBalance = testLUVCoin.balanceOf(defaultAdmin);
    assert(endingLUVBalance == startingLUVBalance - (100 * sfluvExp));
}

function testLiquidityPool () public {
    // Send some HONEY to the zapper from whale
    vm.startPrank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
    honeyToken.transfer(address(testSFLUVZapper), 1000 * 1e18);
    vm.stopPrank();

    // Assert the zapper has 1000 HONEY
    assert(honeyToken.balanceOf(address(testSFLUVZapper)) == 1000 * 1e18);

    // Pull initial sqrtPriceX96 from the liquidity pool
    (uint160 sqrtPriceX96,,,,,,) = liquidityPool.slot0();

    // 95% minimum output
    // sqrt(1 / 0.95) ≈ 1.025978352
    // Determine slippage tolerance
    uint256 NUM = 1_025_978_352; // scaled by 1e9
    uint256 DEN = 1_000_000_000;

    uint256 sqrtPriceLimitX96 = uint256(
        (uint256(sqrtPriceX96) * NUM) / DEN
    );

    // swap 500 HONEY for BYUSD using the liquidity pool
    vm.startPrank(address(testSFLUVZapper));
    liquidityPool.swap(
        address(testSFLUVZapper),
        false,
        int256(500 * 1e18),
        uint160(sqrtPriceLimitX96),
        ""
    );
    vm.stopPrank();

    // Assert that after the swap, the zapper has more than 490 BYUSD and 500 HONEY
    assert(testBYUSD.balanceOf(address(testSFLUVZapper)) > 490000000);
    assert(honeyToken.balanceOf(address(testSFLUVZapper)) == 500000000000000000000);
    }
}
