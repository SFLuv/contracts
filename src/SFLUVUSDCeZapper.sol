// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@berachain/contracts/honey/IHoneyFactory.sol";
import "@berachain/contracts/honey/HoneyFactory.sol";
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { ILiquidityPool } from "./ILiquidityPool.sol";
import "./ISFLUVZapperErrors.sol";
import "./SFLUVv2.sol";

interface IUSDCe is IERC20Metadata {}

interface IOFTAdapter is IOFT {}

struct SFLUVUSDCeZapperStorageInit {
    address honeyFactory;
    address sfluv;
    address honey;
    address usdc;
    address usdcAdapter;
    address usdcVault;
    address honeyToUSDCPool;
    uint32 usdcDstEid;
}

contract SFLUVUSDCeZapper is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ISFLUVZapperErrors
{
    // these roles need to match corresponding roles in SFLUVv2
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER");

    /* STORAGE */
    struct SFLUVUSDCeZapperStorage {
        IHoneyFactory honeyFactory;
        SFLUVv2 sfluv;
        IERC20Metadata honey;
        IUSDCe usdc;
        IOFTAdapter usdcAdapter;
        address usdcVault;
        ILiquidityPool honeyToUSDCPool;
        uint32 usdcDstEid;
    }

    // keccak256(abi.encode(uint256(keccak256("SFLUV.storage.SFLUVUSDCeZapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SFLUVUSDCeZapperStorageLocation =
        0x4b0052a517f33f1f1b7e6b3a321c7f53e23bc343d8df724c8dc01d1fd1b97f00;

    function _getSFLUVUSDCeZapperStorage()
        private
        pure
        returns (SFLUVUSDCeZapperStorage storage $)
    {
        assembly {
            $.slot := SFLUVUSDCeZapperStorageLocation
        }
    }

    modifier onlySFLUVRole(bytes32 role) {
        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();

        if (!$.sfluv.hasRole(role, _msgSender()))
            revert AccessControlUnauthorizedAccount(_msgSender(), role);
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _governance,
        SFLUVUSDCeZapperStorageInit calldata _storage
    )
        initializer
        public
    {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Storage_init(_storage);

        _grantRole(DEFAULT_ADMIN_ROLE, _governance);
    }

    function __Storage_init(
        SFLUVUSDCeZapperStorageInit calldata s
    ) internal onlyInitializing {
        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();

        if (s.honeyFactory == address(0)) revert ZeroAddress();
        $.honeyFactory = IHoneyFactory(s.honeyFactory);

        if (s.sfluv == address(0)) revert ZeroAddress();
        $.sfluv = SFLUVv2(s.sfluv);

        if (s.honey == address(0)) revert ZeroAddress();
        $.honey = IERC20Metadata(s.honey);

        if (s.usdc == address(0)) revert ZeroAddress();
        $.usdc = IUSDCe(s.usdc);

        if (s.usdcAdapter == address(0)) revert ZeroAddress();
        $.usdcAdapter = IOFTAdapter(s.usdcAdapter);

        if (s.usdcVault == address(0)) revert ZeroAddress();
        $.usdcVault = s.usdcVault;

        if (s.honeyToUSDCPool == address(0)) revert ZeroAddress();
        $.honeyToUSDCPool = ILiquidityPool(s.honeyToUSDCPool);

        if (s.usdcDstEid == 0) revert ZeroAddress();
        $.usdcDstEid = s.usdcDstEid;

        $.usdc.approve(address($.honeyFactory), type(uint256).max);
        $.usdc.approve(address($.usdcAdapter), type(uint256).max);
        $.honeyFactory.honey().approve(address($.sfluv), type(uint256).max);
    }

    function setHoneyToUSDCPool(address pool) public onlyRole(DEFAULT_ADMIN_ROLE) {
        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();
        $.honeyToUSDCPool = ILiquidityPool(pool);
    }

    function setUsdcDstEid(uint32 eid) public onlyRole(DEFAULT_ADMIN_ROLE) {
        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();
        $.usdcDstEid = eid;
    }

    function setUsdcAdapter(address adapter) public onlyRole(DEFAULT_ADMIN_ROLE) {
        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();
        $.usdcAdapter = IOFTAdapter(adapter);
        $.usdc.approve(address($.usdcAdapter), type(uint256).max);
    }

    function setUsdcVault(address vault) public onlyRole(DEFAULT_ADMIN_ROLE) {
        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();
        $.usdcVault = vault;
    }

    function unwrapSwapAndBridgeUSDCe(uint256 amount, address to)
        public
        onlySFLUVRole(REDEEMER_ROLE)
        nonReentrant
        returns (MessagingReceipt memory, OFTReceipt memory)
    {
        // amount is 18 decimals, for SFLUV
        return _unwrapSwapAndBridgeUSDCe(amount, to);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external {
        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();

        require(msg.sender == address($.honeyToUSDCPool), "unauthorized pool");

        if (amount0Delta > 0) {
            IERC20Metadata($.honeyToUSDCPool.token0()).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20Metadata($.honeyToUSDCPool.token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    /* INTERNAL */

    function _unwrapSwapAndBridgeUSDCe(uint256 amount, address to) private
        returns (MessagingReceipt memory, OFTReceipt memory) {
        uint256 usdcAmount = FixedPointMathLib.mulDiv(
            amount,
            10 ** _getSFLUVUSDCeZapperStorage().usdc.decimals(),
            10 ** _getSFLUVUSDCeZapperStorage().sfluv.decimals()
        );

        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();
        // 1. Pull SFLUV
        bool success = $.sfluv.transferFrom(_msgSender(), address(this), amount);
        if (!success) revert TransferFailed(address($.sfluv), address(this), _msgSender(), amount);

        // 2. Unwrap to HONEY
        success = $.sfluv.withdrawTo(address(this), amount);
        if (!success) revert RedeemFailed();
        uint256 honeyBalance = $.honey.balanceOf(address(this));

        // 2.5 tracking USDC.e before redeem/swap process just in case amount is insufficient
        uint256 usdcBefore = $.usdc.balanceOf(address(this));

        // 3. Check USDC.e inside Honey, and keep track of how much is redeemed
        HoneyFactory hf = HoneyFactory(address($.honeyFactory));
        uint256 usdcCurrentFees = hf.collectedAssetFees(address($.usdc));
        uint256 usdcAvailableInHoney = ($.usdc.balanceOf($.usdcVault) * 1e12) - (2 * usdcCurrentFees);

        if (usdcAvailableInHoney > 0) {
            uint256 redeemAmount = honeyBalance < usdcAvailableInHoney
                ? honeyBalance
                : usdcAvailableInHoney;

            $.honeyFactory.redeem(address($.usdc), redeemAmount, address(this), false);
            honeyBalance -= redeemAmount;
        }

        // 4. Swap remaining HONEY via pool if needed
        if (honeyBalance > 0) {
            (uint160 sqrtPriceX96,,,,,,) = $.honeyToUSDCPool.slot0();

            // 95% minimum output
            // sqrt(1 / 0.95) ≈ 1.025978352
            uint256 NUM = 1_025_978_352; // scaled by 1e9
            uint256 DEN = 1_000_000_000;

            uint160 sqrtPriceLimitX96 = uint160(
                (uint256(sqrtPriceX96) * NUM) / DEN
            );

            $.honeyToUSDCPool.swap(
                address(this),
                false,
                int256(honeyBalance),
                sqrtPriceLimitX96,
                ""
            );
        }

        uint256 usdcAfter = $.usdc.balanceOf(address(this));
        uint256 usdcAccumulated = usdcAfter - usdcBefore;
        require(usdcAccumulated >= (usdcAmount * 95 / 100), "insufficient USDC.e from swap/redemption");

        // Prepare LZ send params
        SendParam memory lzParam = SendParam({
            dstEid: $.usdcDstEid,
            to: bytes32(uint256(uint160(to))),
            amountLD: usdcAmount,
            minAmountLD: usdcAmount * 95 / 100,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        // 5. Bridge final USDC.e balance
        MessagingFee memory fee = $.usdcAdapter.quoteSend(lzParam, false);
        require(
            $.usdc.balanceOf(address(this)) >= lzParam.minAmountLD,
            "insufficient USDC.e after swap"
        );

        (
            MessagingReceipt memory mReceipt,
            OFTReceipt memory oReceipt
        ) = $.usdcAdapter.send{ value: fee.nativeFee }(lzParam, fee, address(this));

        return (mReceipt, oReceipt);
    }

    // allow receipt of BERA
    receive() external payable {}

    function recoverTo(address payable to) public onlyRole(DEFAULT_ADMIN_ROLE) {
        SFLUVUSDCeZapperStorage storage $ = _getSFLUVUSDCeZapperStorage();
        (bool ok, ) = to.call{ value: address(this).balance }("");
        require(ok, "native transfer failed");
        uint256 usdcBalance = $.usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            $.usdc.approve(to, usdcBalance); // recover all usdc funds
            $.usdc.transfer(to, usdcBalance);
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
