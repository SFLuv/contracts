// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ILiquidityPool {
    /// Swap token0 <-> token1
    /// @param recipient Address receiving output tokens
    /// @param zeroForOne True = token0 → token1, false = token1 → token0
    /// @param amountSpecified Positive = exact input, negative = exact output
    /// @param sqrtPriceLimitX96 Q64.96 price limit, 0 = no limit
    /// @param data Bytes passed to callback
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0Delta, int256 amount1Delta);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );
}
