pragma solidity ^0.8.26;

import "../src/MockCoin.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract SFLUVv2Test is Test {
    MockCoin public mockCoin;
    SFLUVv2 public testLUVCoin;

    address internal gov;
    address internal payer;
    address internal payee;

    uint public oneEther = 1 ether; // TODO: elsewhere?

    ERC1967Proxy proxy;

    function setUp() public {
        mockCoin = new MockCoin();
        testLUVCoin = new SFLUVv2();

        gov = makeAddr("gov");
        payer = makeAddr("payer");
        payee = makeAddr("payee");

        proxy = new ERC1967Proxy(address(testLUVCoin), abi.encodeCall(testLUVCoin.initialize, (gov, mockCoin)));

        testLUVCoin = SFLUVv2(address(proxy));
    }

    function testTokenFunctionality() public {

        mockCoin.mint(gov, 100 * oneEther);

        vm.prank(gov);
        mockCoin.approve(address(testLUVCoin), 100 * oneEther);

        assert(testLUVCoin.balanceOf(gov) == 0);
        assert(!testLUVCoin.hasRole(testLUVCoin.MINTER_ROLE(), gov));

        // gov has the default admin role
        assert(testLUVCoin.hasRole(testLUVCoin.DEFAULT_ADMIN_ROLE(), gov));

        // the default admin role is also the minter admin role
        assert(testLUVCoin.getRoleAdmin(testLUVCoin.MINTER_ROLE()) == testLUVCoin.DEFAULT_ADMIN_ROLE());

        // got pranked by this :/
        vm.startPrank(gov);
        testLUVCoin.grantRole(testLUVCoin.MINTER_ROLE(), gov);
        vm.stopPrank();

        // mint sfluv to payer
        vm.prank(gov);
        testLUVCoin.depositFor(payer, 100 * oneEther);
        assert(testLUVCoin.balanceOf(payer) == 100 * oneEther);

        // transfer some to payee
        vm.prank(payer);
        testLUVCoin.transfer(payee, 50 * oneEther);
        assert(testLUVCoin.balanceOf(payee) == 50 * oneEther);

        // allow payee to unwrap
        vm.startPrank(gov);
        testLUVCoin.grantRole(testLUVCoin.REDEEMER_ROLE(), payee);
        vm.stopPrank();

        // payee unwraps
        vm.prank(payee);
        testLUVCoin.withdrawTo(payee, 50 * oneEther);
        assert(mockCoin.balanceOf(payee) == 50 * oneEther);
    }

    function testAdminRoles() public {

        assert(testLUVCoin.getRoleAdmin(testLUVCoin.MINTER_ROLE()) == testLUVCoin.DEFAULT_ADMIN_ROLE());

        // set the admin role for minting
        vm.startPrank(gov);
        testLUVCoin.setAdminRole(testLUVCoin.MINTER_ROLE(), testLUVCoin.MINTER_ADMIN_ROLE());
        vm.stopPrank();

        assert(testLUVCoin.getRoleAdmin(testLUVCoin.MINTER_ROLE()) == testLUVCoin.MINTER_ADMIN_ROLE());

        // grant minter admin to payer
        vm.startPrank(gov);
        testLUVCoin.grantRole(testLUVCoin.MINTER_ADMIN_ROLE(), payer);
        vm.stopPrank();

        // payer grants minter role to payee
        vm.startPrank(payer);
        testLUVCoin.grantRole(testLUVCoin.MINTER_ROLE(), payee);
        vm.stopPrank();

        assert(testLUVCoin.hasRole(testLUVCoin.MINTER_ROLE(), payee));

    }
}