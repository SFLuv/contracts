// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {
    MessagingFee
} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";

interface ILayerZeroEndpoint {
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;
}

contract BYUSDBridger is Ownable {
    OFT public immutable byusdOFT;
    ILayerZeroEndpoint public immutable lzEndpoint;

    event BridgeInitiated(
        address indexed sender,
        uint16 dstChainId,
        address indexed recipient,
        uint256 amount
    );

    constructor(address _byusdOFT, address _lzEndpoint) Ownable(msg.sender) {
        byusdOFT = OFT(_byusdOFT);
        lzEndpoint = ILayerZeroEndpoint(_lzEndpoint);
    }

    /**
     * @notice Bridge BYUSD to another chain (e.g., Ethereum)
     * @param _dstChainId The destination LayerZero chain ID (Ethereum = 30362)
     * @param _recipient The recipient on the destination chain
     * @param _amount The amount of BYUSD to bridge (6 decimals)
     * @param _adapterParams Optional adapter params (e.g., gas limit)
     */
    function bridgeBYUSD(
        uint16 _dstChainId,
        address _recipient,
        uint256 _amount,
        bytes calldata _adapterParams
    ) external payable {
        // Transfer BYUSD from sender to this contract
        require(
            IERC20(address(byusdOFT)).transferFrom(
                msg.sender,
                address(this),
                _amount
            ),
            "Transfer failed"
        );

        // Approve BYUSD to OFT contract
        IERC20(address(byusdOFT)).approve(address(byusdOFT), _amount);

        // Construct SendParam
        SendParam memory sendParam = SendParam(
            uint32(_dstChainId),
            bytes32(uint256(uint160(_recipient))),
            _amount,
            _amount, // minAmountLD
            _adapterParams, // extraOptions
            "", // composeMsg
            "" // oftCmd
        );

        // Construct MessagingFee
        MessagingFee memory fee = MessagingFee(msg.value, 0);

        // Call OFT send to destination chain
        byusdOFT.send{value: msg.value}(
            sendParam,
            fee,
            msg.sender // refundAddress
        );

        emit BridgeInitiated(msg.sender, _dstChainId, _recipient, _amount);
    }
}
