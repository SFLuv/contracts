
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


interface BYUSD {
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract SFLUVZapperTest is Test {
    SFLUVv2 public testLUVCoin;
    SFLUVZapperv1 public testSFLUVZapper;
    BYUSD public testBYUSD;

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
        testLUVCoin = SFLUVv2(sfluv);
        testBYUSD = BYUSD(byusd);
        testSFLUVZapper = new SFLUVZapperv1();

        peon = makeAddr("peon");

        address lzbridge = address(0x1);
        address honeyFactory = vm.envAddress("HONEY_FACTORY_ADDRESS");

        SFLUVZapperStorageInit memory testStorage = SFLUVZapperStorageInit(
            lzbridge,
            honeyFactory,
            sfluv,
            byusd
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

}
