pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MintSFLUVv2 is Script {

    uint public oneEther = 1 ether;

    address constant private SFLUV_V2_ADDR = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    address constant private BASE_COIN_ADDR = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;

    function run() public {

        vm.startBroadcast();

         IERC20 base = IERC20(BASE_COIN_ADDR);
         SFLUVv2 impl = SFLUVv2(SFLUV_V2_ADDR);

        // assume that msg.sender is default admin
        if (!impl.hasRole(impl.MINTER_ROLE(), msg.sender)) {
            impl.grantRole(impl.MINTER_ROLE(), msg.sender);
        }

        uint256 toMintAmt = 100 * oneEther;

        assert(base.balanceOf(msg.sender) >= toMintAmt);
        base.approve(SFLUV_V2_ADDR, toMintAmt);

        impl.depositFor(msg.sender, toMintAmt);

        uint256 balance = impl.balanceOf(msg.sender);

        vm.stopBroadcast();

        console.log("Balance after minting:", balance);
    }
}