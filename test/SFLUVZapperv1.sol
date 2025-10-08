pragma solidity ^0.8.26;

import "../src/MockCoin.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import {SFLUVZapperv1, SFLUVZapperStorageInit} from "../src/SFLUVZapperv1.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
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
    MockCoin public mockCoin;
    SFLUVv2 public testLUVCoin;
    SFLUVZapperv1 public testSFLUVZapper;
    BYUSD public testBYUSD;

    address internal gov;
    address internal payer;
    address internal payee;

    uint public oneEther = 1 ether; // TODO: elsewhere?

    ERC1967Proxy zapperproxy;

    function setUp() public {
        string memory forkURL = vm.envString('FORK_URL');
        uint256 forkBlock = vm.envUint('FORK_BLOCK');


        vm.createSelectFork(forkURL, forkBlock);
        // mockCoin = new MockCoin();
        address sfluv = vm.envAddress('SFLUV_ADDRESS');
        address byusd = vm.envAddress("BYUSD_ADDRESS");
        testLUVCoin = SFLUVv2(sfluv);
        testBYUSD = BYUSD(byusd);
        testSFLUVZapper = new SFLUVZapperv1();

        gov = makeAddr("gov");
        payer = makeAddr("payer");
        payee = makeAddr("payee");

        address lzbridge = address(0x1);
        address honeyFactory = vm.envAddress("HONEY_FACTORY_ADDRESS");



        SFLUVZapperStorageInit memory testStorage = SFLUVZapperStorageInit(
            lzbridge,
            honeyFactory,
            sfluv,
            byusd
            );

        console.log(lzbridge, honeyFactory, sfluv, byusd);
        console.log(address(testSFLUVZapper));
        zapperproxy = new ERC1967Proxy(address(testSFLUVZapper), abi.encodeCall(testSFLUVZapper.initialize, (gov, testStorage)));
        testSFLUVZapper = SFLUVZapperv1(address(zapperproxy));
    }


    function testWrappingFunctionality() public {
        // Prank w/ BYUSD whale address
        vm.prank(0x4Be03f781C497A489E3cB0287833452cA9B9E80B);
        testBYUSD.transfer(address(testSFLUVZapper), 100);
         uint256 testBalance = testBYUSD.balanceOf(address(testSFLUVZapper));
        console.log(testBalance);
        // Send BYUSD to Zapper contract

        // Zap BYUSD to SFLUV
        // Send SFLUV to reciever
        // Confirm reciever has the right amount of SFLUV

    }

    function testUnwrappingFunctionality() public {

        // Prank w/ SFLUV whale address
        // Send SFLUV to Zapper contract
        // Zap SFLUV to BYUSD
        // Send BYUSD to reciever
        // Confirm reciever has the right amount of BYUSD


    }

}
