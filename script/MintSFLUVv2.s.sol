pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MintSFLUVv2 is Script {

    uint public oneEther = 1 ether;
    uint public oneGwei = 1 gwei;

    // mainnet
    address constant private SFLUV_V2_ADDR = 0x881cAd4f885c6701D8481c0eD347f6d35444eA7e;
    // HONEY on Berachain main
    address constant private BASE_COIN_ADDR = 0xFCBD14DC51f0A4d49d5E53C2E0950e0bC26d0Dce;

    function run() public {

        vm.startBroadcast();

         IERC20 base = IERC20(BASE_COIN_ADDR);
         SFLUVv2 impl = SFLUVv2(SFLUV_V2_ADDR);

        // assume that msg.sender has minter admin role
        if (!impl.hasRole(impl.MINTER_ROLE(), msg.sender)) {
            impl.grantRole(impl.MINTER_ROLE(), msg.sender);
        }

        uint256 toMintAmt = 5 * oneEther; // 5 HONEY

        assert(base.balanceOf(msg.sender) >= toMintAmt);
        base.approve(SFLUV_V2_ADDR, toMintAmt);

        impl.depositFor(msg.sender, toMintAmt);

        uint256 balance = impl.balanceOf(msg.sender);

        vm.stopBroadcast();

        console.log("Balance after minting:", balance);
    }
}