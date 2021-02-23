// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "./UniswapLib.sol";

contract UniswapLpTokenView {    
    /// @notice Constant indicating that this contract is a UniswapLpTokenView
    bool constant public IS_UNISWAP_LP_TOKEN_VIEW = true;
    
    /// @notice Boolean indicating if `msg.sender` is to be used as the root oracle instead of using current Uniswap market conditions
    bool public useRootOracle = true;

    /**
     * @notice Construct a Uniswap LP token price view
     * @param _useRootOracle Boolean indicating if `msg.sender` is to be used as the root oracle instead of using current Uniswap market conditions
     */
    constructor(bool _useRootOracle) public {
        useRootOracle = _useRootOracle;
    }

    /**
     * @dev WETH contract address.
     */
    address constant private WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /**
     * @notice Get the official price for an underlying token address
     * @param underlying The underlying token address for which to get the price (set to zero address for ETH)
     * @return Price denominated in ETH, with 18 decimals
     */
    function price(address underlying) external view returns (uint) {
        return fetchLpTokenPrice(underlying);
    }

    /**
     * @notice Get the underlying price of a cToken
     * @dev Implements the PriceOracle interface for Compound v2.
     * @param cToken The cToken address for price retrieval
     * @return Price denominated in ETH, with 18 decimals, for the given cToken address
     */
    function getUnderlyingPrice(address cToken) external view returns (uint) {
        address underlying = CErc20(cToken).underlying();
        // Comptroller needs prices in the format: ${raw price} * 1e(36 - baseUnit)
        // Since the prices in this view have 18 decimals, we must scale them by 1e(36 - 18 - baseUnit)
        return mul(1e18, fetchLpTokenPrice(underlying)) / (10 ** uint256(IERC20(underlying).decimals()));
    }

    /**
     * @dev Fetches the fair LP token token/ETH price from Uniswap, with 18 decimals of precision.
     */
    function fetchLpTokenPrice(address token) internal view virtual returns (uint) {
        IUniswapV2Pair pair = IUniswapV2Pair(token);
        uint totalSupply = pair.totalSupply();
        (uint reserve0, uint reserve1, uint blockTimestampLast) = pair.getReserves();
        address token0 = pair.token0();
        address token1 = pair.token1();

        if (useRootOracle) {
            // Get fair price of non-WETH token (underlying the pair) in terms of ETH
            uint token0FairPrice = token0 == WETH_ADDRESS ? 1e18 : BasePriceOracle(msg.sender).price(token0);
            uint token1FairPrice = token1 == WETH_ADDRESS ? 1e18 : BasePriceOracle(msg.sender).price(token1);

            // Implementation from https://github.com/AlphaFinanceLab/homora-v2/blob/e643392d582c81f6695136971cff4b685dcd2859/contracts/oracle/UniswapV2Oracle.sol#L18
            uint sqrtK = sqrt(mul(reserve0, reserve1)) / totalSupply;
            return mul(mul(mul(sqrtK, 2), sqrt(token0FairPrice)) / (2 ** 56), sqrt(token1FairPrice)) / (2 ** 56);
        } else {
            // Get current LP token price (ETH-based pairs only)
            require(block.timestamp > blockTimestampLast, "Uniswap LP token was updated in this block. Reverting due to risk of price manipulation.");
            require(token0 == WETH_ADDRESS || token1 == WETH_ADDRESS, "Uniswap LP token not based in ETH and root oracle not available.");
            return mul(mul(token0 == WETH_ADDRESS ? reserve0 : reserve1, 2), 1e18) / totalSupply;
        }
    }

    /// @dev Overflow proof multiplication
    function mul(uint a, uint b) internal pure returns (uint) {
        if (a == 0) return 0;
        uint c = a * b;
        require(c / a == b, "multiplication overflow");
        return c;
    }

    /// @dev implementation from https://github.com/Uniswap/uniswap-lib/commit/99f3f28770640ba1bb1ff460ac7c5292fb8291a0
    /// original implementation: https://github.com/abdk-consulting/abdk-libraries-solidity/blob/master/ABDKMath64x64.sol#L687
    function sqrt(uint x) internal pure returns (uint) {
        if (x == 0) return 0;
        uint xx = x;
        uint r = 1;

        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }

        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1; // Seven iterations should be enough
        uint r1 = x / r;
        return (r < r1 ? r : r1);
    }
}
