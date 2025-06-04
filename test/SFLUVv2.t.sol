pragma solidity ^0.8.26;

import "../src/MockCoin.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import {Test} from "forge-std/Test.sol";

contract SFLUVv2Test is Test {
    MockCoin public mockCoin;
    SFLUVv2 public testLUVCoin;

    address internal gov;
    address internal payer;
    address internal payee;

    uint public oneEther = 1 ether; // TODO: elsewhere?

    function setUp() public {
        mockCoin = new MockCoin();
        testLUVCoin = new SFLUVv2();

        gov = makeAddr("gov");
        payer = makeAddr("payer");
        payee = makeAddr("payee");

        // testLUVCoin.initialize(gov, mockCoin);
    }

}