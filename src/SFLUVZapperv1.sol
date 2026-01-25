pragma solidity ^0.8.26;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20WrapperUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@berachain/contracts/honey/IHoneyFactory.sol";
import "@berachain/contracts/honey/HoneyFactory.sol";
import "@berachain/contracts/honey/Honey.sol";
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { FixedPointMathLib } from "solady/src/utils/FixedPointMathLib.sol";
import { ILiquidityPool} from "./ILiquidityPool.sol";
import "forge-std/console.sol";
import "./ISFLUVZapperErrors.sol";
import "./SFLUVv2.sol";

interface IBYUSD is IERC20Metadata, IOFT {}

struct SFLUVZapperStorageInit {
  address honeyFactory;
  address sfluv;
  address byusd;
  address honey;
  address honeyToBYUSDPool;
  address byusdVault;
}

contract SFLUVZapperv1 is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ISFLUVZapperErrors
{
    // these roles need to match corresponding roles in SFLUVv2
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");
    // bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN");

    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER");
    // bytes32 public constant REDEEMER_ADMIN_ROLE = keccak256("REDEEMER_ADMIN");

    /* STORAGE */

    struct SFLUVZapperStorage {
        IHoneyFactory honeyFactory;
        SFLUVv2 sfluv;

        IBYUSD byusd;
        IERC20Metadata honey;

        ILiquidityPool honeyToBYUSDPool;

        address byusdVault;
    }

    // keccak256(abi.encode(uint256(keccak256("SFLUV.storage.SFLUVZapper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SFLUVZapperStorageLocation =
        0x4387e05f939ab688c86fd2a91847d45cedf6bd707f41c3ea87ea7383b559aa00;

    function _getSFLUVZapperStorage()
        private
        pure
        returns (SFLUVZapperStorage storage $)
    {
        assembly {
            $.slot := SFLUVZapperStorageLocation
        }
    }

    modifier onlySFLUVRole(bytes32 role) {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        if (!$.sfluv.hasRole(role, _msgSender()))
            revert AccessControlUnauthorizedAccount(_msgSender(), role);
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _governance,
        SFLUVZapperStorageInit calldata _storage
    )
        initializer
        public
    {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Storage_init(_storage);

        _grantRole(DEFAULT_ADMIN_ROLE, _governance);

//        _setRoleAdmin(MINTER_ROLE, MINTER_ADMIN_ROLE);
//        _setRoleAdmin(REDEEMER_ROLE, REDEEMER_ADMIN_ROLE);
    }

    function __Storage_init(
        SFLUVZapperStorageInit calldata s
    ) internal onlyInitializing {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        if (s.honeyFactory == address(0)) revert ZeroAddress();
        $.honeyFactory = IHoneyFactory(s.honeyFactory);

        if (s.sfluv == address(0)) revert ZeroAddress();
        $.sfluv = SFLUVv2(s.sfluv);

        if (s.byusd == address(0)) revert ZeroAddress();
        $.byusd = IBYUSD(s.byusd);

        if (s.honey == address(0)) revert ZeroAddress();
        $.honey = IERC20Metadata(s.honey);

        if (s.honeyToBYUSDPool == address(0)) revert ZeroAddress();
        $.honeyToBYUSDPool = ILiquidityPool(s.honeyToBYUSDPool);

        if (s.byusdVault == address(0)) revert ZeroAddress();
        $.byusdVault = s.byusdVault;

        $.byusd.approve(s.honeyFactory, type(uint256).max);
        $.byusd.approve(s.byusd, type(uint256).max);
        $.honeyFactory.honey().approve(s.sfluv, type(uint256).max);
    }

    function setLiquidityPool(address pool) public onlyRole(DEFAULT_ADMIN_ROLE) {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();
        $.honeyToBYUSDPool = ILiquidityPool(pool);
    }

    function zapIn(uint256 amount) external onlySFLUVRole(MINTER_ROLE) nonReentrant {
        _zapInTo(amount, _msgSender());
    }

    function zapInTo(uint256 amount, address to) public onlySFLUVRole(MINTER_ROLE) nonReentrant {
        _zapInTo(amount, to);
    }

    function zapOut(uint256 amount) external onlySFLUVRole(REDEEMER_ROLE) nonReentrant {
        _zapOutTo(amount, _msgSender());
    }

    function zapOutTo(uint256 amount, address to) public onlySFLUVRole(REDEEMER_ROLE) nonReentrant {
        _zapOutTo(amount, to);
    }

    function zapOutAndLzBridgeTo(SendParam calldata lzParam) public onlySFLUVRole(REDEEMER_ROLE) nonReentrant {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        uint256 zapAmount = FixedPointMathLib.mulDiv(
            lzParam.amountLD,
            10 ** $.sfluv.decimals(),
            10 ** $.byusd.decimals()
        );

        _zapOutTo(zapAmount, address(this));

        MessagingFee memory fee = $.byusd.quoteSend(lzParam, false);
        (
            MessagingReceipt memory mReceipt,
            OFTReceipt memory oReceipt
        ) = $.byusd.send{ value: fee.nativeFee }(
            lzParam,
            fee,
            address(this)
        );
    }

    function unwrapSwapAndBridge(uint256 amount, address to) public onlySFLUVRole(REDEEMER_ROLE) returns (MessagingReceipt memory, OFTReceipt memory) {
       //amount is 18 decimals, for SFLUV
       return(_unwrapSwapAndBridge(amount, to));
    }

    function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata
    ) external {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        require(msg.sender == address($.honeyToBYUSDPool), "unauthorized pool");

        if (amount0Delta > 0) {
            IERC20Metadata($.honeyToBYUSDPool.token0()).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20Metadata($.honeyToBYUSDPool.token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    /* INTERNAL */

    function _zapInTo(uint256 amount, address to) private {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        bool success = $.byusd.transferFrom(
            _msgSender(),
            address(this),
            amount
        );
        if (!success) revert TransferFailed(address($.byusd), address(this), _msgSender(), amount);

        uint256 honeyAmount = $.honeyFactory.mint(
            address($.byusd),
            amount,
            address(this),
            false
        );

        success = $.sfluv.depositFor(to, honeyAmount);
        if (!success) revert MintFailed();
    }

    function _zapOutTo(uint256 amount, address to) private {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();

        bool success = $.sfluv.transferFrom(
            _msgSender(),
            address(this),
            amount
        );
        if (!success) revert TransferFailed(address($.sfluv), address(this), _msgSender(), amount);

        success = $.sfluv.withdrawTo(address(this), amount);
        if (!success) revert RedeemFailed();

        $.honeyFactory.redeem(
            address($.byusd),
            amount,
            to,
            false
        );
    }

    function _unwrapSwapAndBridge(uint256 amount, address to) private
        returns (MessagingReceipt memory, OFTReceipt memory) {
        uint byusdAmount = FixedPointMathLib.mulDiv(
            amount,
            10 ** _getSFLUVZapperStorage().byusd.decimals(),
            10 ** _getSFLUVZapperStorage().sfluv.decimals()
        );
//        console.log("amount passed in:", amount);
//        console.log("BYUSD amount passed in:", byusdAmount);
//        console.log("address passed in:", to);

        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();
        // 1. Pull SFLUV
        bool success = $.sfluv.transferFrom(_msgSender(), address(this), amount);
        if (!success) revert TransferFailed(address($.sfluv), address(this), _msgSender(), amount);
//        console.log("SFLUV transferred into Zapper contract:", amount);

        // 2. Unwrap to HONEY
        success = $.sfluv.withdrawTo(address(this), amount);
        if (!success) revert RedeemFailed();
        uint256 honeyBalance = $.honey.balanceOf(address(this));
//        console.log("HONEY balance after redeem:", honeyBalance);

        // 2.5 tracking BYUSD before redeem/swap process just in case amount is insufficient
        uint256 byusdBefore = $.byusd.balanceOf(address(this));
//        console.log("BYUSD balance before redeem/swap:", byusdBefore);

        // 3. Check BYUSD inside Honey, and keep track of how much is redeemed
        // needs to actually respect this calc - but not public
        //     function _getSharesWithoutFees(address asset) internal view returns (uint256) {
        //        return vaults[asset].balanceOf(address(this)) - collectedAssetFees[asset];
        //    }
        HoneyFactory hf = HoneyFactory(address($.honeyFactory));
        // *** this gets the balance of BYUSD in HONEY in BYUSD decimals
        // uint256 byusdAvailable = $.byusd.balanceOf($.byusdVault) - byusdCurrentFees;
        uint256 byusdCurrentFees = hf.collectedAssetFees(address($.byusd));
        // this gets the balance of BYUSD in HONEY decimals - i.e. 'shares'
        uint256 byusdAvailableInHoney = hf.vaults(address($.byusd)).balanceOf(address($.honeyFactory)) - byusdCurrentFees;

        if (byusdAvailableInHoney > 0) {
            uint256 redeemAmount = honeyBalance < byusdAvailableInHoney
                ? honeyBalance
                : byusdAvailableInHoney;

            $.honeyFactory.redeem(address($.byusd), redeemAmount, address(this), false);
            honeyBalance -= redeemAmount;
            console.log("Redeemed BYUSD from HONEY:", redeemAmount / 1e12);
        }

        // 4. Swap remaining HONEY via pool if needed
        if (honeyBalance > 0) {
            (uint160 sqrtPriceX96,,,,,,) = $.honeyToBYUSDPool.slot0();

            // 95% minimum output
            // sqrt(1 / 0.95) ≈ 1.025978352
            uint256 NUM = 1_025_978_352; // scaled by 1e9
            uint256 DEN = 1_000_000_000;

            uint160 sqrtPriceLimitX96 = uint160(
                (uint256(sqrtPriceX96) * NUM) / DEN
            );

            $.honeyToBYUSDPool.swap(
                address(this),
                false,
                int256(honeyBalance),
                sqrtPriceLimitX96,
                ""
            );
//            console.log("Swapped remaining HONEY for BYUSD:", honeyBalance);
        }

        uint256 byusdAfter = $.byusd.balanceOf(address(this));
//        console.log("BYUSD balance after redeem/swap:", byusdAfter);
        uint256 byusdAccumulated = byusdAfter - byusdBefore;
//        console.log("amount we're comparing BYUSD accumulated against:", byusdAmount * 95 / 100);
//        console.log("BYUSD accumulated from redeem/swap:", byusdAccumulated);
        require(byusdAccumulated >= (byusdAmount * 95 / 100), "insufficient BYUSD from swap/redemption");

        // Prepare LZ send params
        SendParam memory lzParam = SendParam({
            dstEid: 30101, //ETH layerzero eid
            to: bytes32(uint256(uint160(to))),
            amountLD: byusdAmount,
            minAmountLD: byusdAmount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        // 5. Bridge final BYUSD balance
        MessagingFee memory fee = $.byusd.quoteSend(lzParam, false);
        require(
        $.byusd.balanceOf(address(this)) >= lzParam.amountLD,
        "insufficient BYUSD after swap"
        );

//        console.log("Zapper Bera balance before bridging:", address(this).balance);
//        console.log("Native fee for bridging:", fee.nativeFee);
//        console.log("LZ token fee for bridging:", fee.lzTokenFee);
//        console.log("Address of this contract:", address(this));
//        console.log("BYUSD's bera balance before bridging:", address($.byusd).balance);
//        console.log("zapper BYUSD balance before bridging:", $.byusd.balanceOf(address(this)));
//        console.logBytes32(lzParam.to);

        (
                MessagingReceipt memory mReceipt,
                OFTReceipt memory oReceipt
            ) = $.byusd.send{ value: fee.nativeFee }(lzParam, fee, address(this));

//        console.log("zapper BYUSD balance after bridging:", $.byusd.balanceOf(address(this)));
//        console.log("Bridging BYUSD amountLD:", lzParam.amountLD);
        return (mReceipt, oReceipt);
    }

    // allow receipt of BERA
    receive() external payable {}

    function recoverTo(address payable to) public onlyRole(DEFAULT_ADMIN_ROLE) {
        SFLUVZapperStorage storage $ = _getSFLUVZapperStorage();
        to.send(address(this).balance); // recover all native funds
        uint256 byusdBalance = $.byusd.balanceOf(address(this));
        if (byusdBalance > 0) {
            $.byusd.approve(to, byusdBalance); // recover all byusd funds
            $.byusd.transfer(to, byusdBalance);
        }
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
