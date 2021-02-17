// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "./UniswapConfig.sol";
import "./UniswapLib.sol";

struct Observation {
    uint timestamp;
    uint acc;
}

contract UniswapDirectView is UniswapConfig {
    using FixedPoint for *;
    
    bool constant public IS_UNISWAP_VIEW = true;

    /// @notice The number of wei in 1 ETH
    uint public constant ethBaseUnit = 1e18;

    /// @notice A common scaling factor to maintain precision
    uint public constant expScale = 1e18;

    /// @notice If new token configs can be added by anyone
    bool public isPublic;

    bytes32 constant ethHash = keccak256(abi.encodePacked("ETH"));

    /**
     * @notice Construct a direct uniswap price view for a set of token configurations
     * @param configs The static token configurations which define what prices are supported and how
     * @param _isPublic If true, anyone can add assets, but they will be validated
     */
    constructor(TokenConfig[] memory configs,
                bool _canAdminOverwrite,
                bool _isPublic) UniswapConfig(configs, _canAdminOverwrite) public {
        // Initialize variables
        isPublic = _isPublic;

        // If public, force set admin to 0, require !canAdminOverwrite, and check token configs
        if (isPublic) {
            admin = address(0);
            require(!canAdminOverwrite, "canAdminOverwrite must be set to false for public UniswapDirectView contracts.");
            checkTokenConfigs(configs);
        }

        // Init token configs
        initConfigs(configs);
    }

    /**
     * @dev UniswapV2Factory contract address.
     */
    address constant private UNISWAP_V2_FACTORY_ADDRESS = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    
    /**
     * @dev WETH contract address.
     */
    address constant private WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /**
     * @dev Verifies token configs
     * @param configs The configs for the supported assets
     */
    function checkTokenConfigs(TokenConfig[] memory configs) internal view {
        for (uint256 i = 0; i < configs.length; i++) {
            // Check symbolHash for ETH
            require(configs[i].symbolHash != ethHash, "ETH does not need a price feed as all price feeds are based in ETH.");

            // Check symbolHash against underlying symbol
            require(keccak256(abi.encodePacked(IERC20(configs[i].underlying).symbol())) == configs[i].symbolHash, "Symbol mismatch between token config and ERC20 symbol method.");

            // Check baseUnit against underlying decimals
            require(10 ** uint256(IERC20(configs[i].underlying).decimals()) == configs[i].baseUnit, "Incorrect token config base unit.");

            // Check for WETH
            if (configs[i].underlying == WETH_ADDRESS) {
                // Check price source
                require(configs[i].priceSource == PriceSource.FIXED_ETH, "Invalid WETH token config price source: must be FIXED_ETH.");
                
                // Check fixed price
                require(configs[i].fixedPrice == 1e18, "WETH token config fixed price must be 1e18.");

                // Check uniswapMarket and isUniswapReversed
                require(configs[i].uniswapMarket == address(0), "WETH Uniswap market not necessary.");
                configs[i].isUniswapReversed = false;
            } else {
                // Check price source
                require(configs[i].priceSource == PriceSource.UNISWAP, "Invalid token config price source: must be UNISWAP.");

                // Check fixed price
                require(configs[i].fixedPrice == 0, "Token config fixed price must be 0.");

                // Check uniswapMarket and isUniswapReversed
                IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(UNISWAP_V2_FACTORY_ADDRESS, configs[i].underlying, WETH_ADDRESS));
                require(configs[i].uniswapMarket == address(pair), "Token config Uniswap market is not correct.");
                address token0 = pair.token0();
                require((token0 == configs[i].underlying && !configs[i].isUniswapReversed) || (token0 != configs[i].underlying && configs[i].isUniswapReversed), "Token config Uniswap reversal is incorrect.");
            }
        }
    }

    /**
     * @notice Initialize token configs
     * @param configs The static token configurations which define what prices are supported and how
     */
    function initConfigs(TokenConfig[] memory configs) internal {
        for (uint i = 0; i < configs.length; i++) {
            TokenConfig memory config = configs[i];
            require(config.baseUnit > 0, "baseUnit must be greater than zero");
            address uniswapMarket = config.uniswapMarket;
            if (config.priceSource == PriceSource.UNISWAP) {
                require(uniswapMarket != address(0), "UNISWAP prices must have a Uniswap market");
            } else {
                require(uniswapMarket == address(0), "only UNISWAP prices utilize a Uniswap market");
            }
        }
    }

    /**
     * @notice Add new asset(s)
     * @param configs The static token configurations which define what prices are supported and how
     */
    function add(TokenConfig[] memory configs) external {
        // If public, check token configs; if private, check that msg.sender == admin
        if (isPublic) checkTokenConfigs(configs);
        else require(msg.sender == admin, "msg.sender is not admin");

        // Add and init token configs
        _add(configs);
        initConfigs(configs);
    }

    /**
     * @notice Get the official price for an underlying token address
     * @param underlying The underlying token address for which to get the price (set to zero address for ETH)
     * @return Price denominated in ETH, with 18 decimals
     */
    function price(address underlying) external view returns (uint) {
        TokenConfig memory config = getTokenConfigByUnderlying(underlying);
        return priceInternal(config);
    }

    function priceInternal(TokenConfig memory config) internal view returns (uint) {
        if (config.priceSource == PriceSource.UNISWAP) return fetchAnchorPrice(config.underlying, config);
        if (config.priceSource == PriceSource.FIXED_USD) {
            uint ethPerUsd = fetchAnchorPrice(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, getTokenConfigByUnderlying(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
            return mul(config.fixedPrice, ethPerUsd) / 1e6;
        }
        if (config.priceSource == PriceSource.FIXED_ETH) return config.fixedPrice;
    }

    /**
     * @notice Get the underlying price of a cToken
     * @dev Implements the PriceOracle interface for Compound v2.
     * @param cToken The cToken address for price retrieval
     * @return Price denominated in ETH, with 18 decimals, for the given cToken address
     */
    function getUnderlyingPrice(address cToken) external view returns (uint) {
        if (CToken(cToken).isCEther()) return 1e18;
        TokenConfig memory config = getTokenConfigByCToken(cToken);
         // Comptroller needs prices in the format: ${raw price} * 1e(36 - baseUnit)
         // Since the prices in this view have 18 decimals, we must scale them by 1e(36 - 18 - baseUnit)
        return mul(1e18, priceInternal(config)) / config.baseUnit;
    }

    /**
     * @dev Fetches the current token/ETH price from Uniswap, with 18 decimals of precision.
     */
    function fetchAnchorPrice(address underlying, TokenConfig memory config) internal virtual returns (uint) {
        (uint reserve0, uint reserve1, ) = IUniswapV2Pair(config.uniswapMarket).getReserves();
        uint rawUniswapPriceMantissa = UniswapV2Library.getAmountOut(config.baseUnit, config.isUniswapReversed ? reserve1 : reserve0, config.isUniswapReversed ? reserve0 : reserve1);
        uint unscaledPriceMantissa = mul(rawUniswapPriceMantissa, 1e18);

        // Adjust rawUniswapPrice according to the units of the non-ETH asset

        // In the case of non-ETH tokens
        // a. priceAverage will always be Token/ETH current price
        // b. conversionFactor = 1e18
        // unscaledPriceMantissa = priceAverage(token/ETH current price) * expScale * conversionFactor
        // so ->
        // anchorPrice = priceAverage * tokenBaseUnit / ethBaseUnit * 1e18
        //             = priceAverage * conversionFactor * tokenBaseUnit / ethBaseUnit
        //             = unscaledPriceMantissa / expScale * tokenBaseUnit / ethBaseUnit
        return mul(unscaledPriceMantissa, config.baseUnit) / ethBaseUnit / expScale;
    }

    /// @dev Overflow proof multiplication
    function mul(uint a, uint b) internal pure returns (uint) {
        if (a == 0) return 0;
        uint c = a * b;
        require(c / a == b, "multiplication overflow");
        return c;
    }
}
