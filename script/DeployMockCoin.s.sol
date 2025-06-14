pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {MockCoin} from "../src/MockCoin.sol";

contract DeployMockCoin is Script {

    uint public oneEther = 1 ether;

    function run() public {
        vm.startBroadcast();
        MockCoin mock = new MockCoin();
        mock.mint(msg.sender, 1000 * oneEther);
        vm.stopBroadcast();
        console.log("Mock Coin Address:", address(mock));
    }
}