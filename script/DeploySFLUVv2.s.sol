pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {SFLUVv2} from "../src/SFLUVv2.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeploySFLUVv2 is Script {

    // TODO: change to correct address of base coin - e.g. HONEY
    address constant private BASE_COIN_ADDR = 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0;

    function run() public {

        vm.startBroadcast();

        IERC20 baseCoin = IERC20(BASE_COIN_ADDR);
        SFLUVv2 impl = new SFLUVv2();

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl),
            abi.encodeCall(impl.initialize, (msg.sender, baseCoin)));

        vm.stopBroadcast();

        console.log("UUPS Proxy Address:", address(proxy));
    }
}