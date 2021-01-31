// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "./UniswapConfig.sol";
import "./UniswapLib.sol";

struct Observation {
    uint timestamp;
    uint acc;
}

contract UniswapView is UniswapConfig {
    using FixedPoint for *;
    
    bool constant public IS_UNISWAP_VIEW = true;

    /// @notice The number of wei in 1 ETH
    uint public constant ethBaseUnit = 1e18;

    /// @notice A common scaling factor to maintain precision
    uint public constant expScale = 1e18;

    /// @notice The minimum amount of time in seconds required for the old uniswap price accumulator to be replaced
    uint public immutable anchorPeriod;

    /// @notice If new token configs can be added by anyone
    bool public isPublic;

    /// @notice Official prices by underlying
    mapping(address => uint) public prices;

    /// @notice The old observation for each underlying
    mapping(address => Observation) public oldObservations;

    /// @notice The new observation for each underlying
    mapping(address => Observation) public newObservations;

    /// @notice The event emitted when the stored price is updated
    event PriceUpdated(address underlying, uint price);

    /// @notice The event emitted when anchor price is updated
    event AnchorPriceUpdated(address underlying, uint anchorPrice, uint oldTimestamp, uint newTimestamp);

    /// @notice The event emitted when the uniswap window changes
    event UniswapWindowUpdated(address indexed underlying, uint oldTimestamp, uint newTimestamp, uint oldPrice, uint newPrice);

    bytes32 constant ethHash = keccak256(abi.encodePacked("ETH"));

    /**
     * @notice Construct a uniswap anchored view for a set of token configurations
     * @dev Note that to avoid immature TWAPs, the system must run for at least a single anchorPeriod before using.
     * @param anchorPeriod_ The minimum amount of time required for the old uniswap price accumulator to be replaced
     * @param configs The static token configurations which define what prices are supported and how
     * @param _isPublic If true, anyone can add assets, but they will be validated
     */
    constructor(uint anchorPeriod_,
                TokenConfig[] memory configs,
                bool _canAdminOverwrite,
                bool _isPublic) UniswapConfig(configs, _canAdminOverwrite) public {
        anchorPeriod = anchorPeriod_;
        isPublic = _isPublic;

        if (isPublic) {
            admin = address(0);
            require(!canAdminOverwrite, "canAdminOverwrite must be set to false for public UniswapView contracts.");
            checkTokenConfigs(configs);
        }

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
                require(configs[i].priceSource == PriceSource.TWAP, "Invalid token config price source: must be TWAP.");

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
            if (config.priceSource == PriceSource.TWAP) {
                require(uniswapMarket != address(0), "TWAP prices must have a Uniswap market");
                address underlying = config.underlying;
                uint cumulativePrice = currentCumulativePrice(config);
                oldObservations[underlying].timestamp = block.timestamp;
                newObservations[underlying].timestamp = block.timestamp;
                oldObservations[underlying].acc = cumulativePrice;
                newObservations[underlying].acc = cumulativePrice;
                emit UniswapWindowUpdated(underlying, block.timestamp, block.timestamp, cumulativePrice, cumulativePrice);
            } else {
                require(uniswapMarket == address(0), "only TWAP prices utilize a Uniswap market");
            }
        }
    }

    /**
     * @notice Add new asset(s)
     * @param configs The static token configurations which define what prices are supported and how
     */
    function add(TokenConfig[] memory configs) external {
        if (!isPublic) require(msg.sender == admin, "msg.sender is not admin");
        if (isPublic) checkTokenConfigs(configs);

        for (uint256 i = 0; i < configs.length; i++) {
            if (!canAdminOverwrite) require(!_configPresenceByUnderlying[configs[i].underlying], "Token config already exists for this underlying token address.");
            _configs.push(configs[i]);
            _configIndexesByUnderlying[configs[i].underlying] = _configs.length - 1;
            _configPresenceByUnderlying[configs[i].underlying] = true;
        }

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
        if (config.priceSource == PriceSource.TWAP) return prices[config.underlying];
        if (config.priceSource == PriceSource.FIXED_USD) {
            uint ethPerUsd = prices[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48];
            require(ethPerUsd > 0, "USDC price not set, cannot convert from USD to ETH");
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
        if (CErc20(cToken).underlying() == address(0)) return 1e18;
        TokenConfig memory config = getTokenConfigByCToken(cToken);
         // Comptroller needs prices in the format: ${raw price} * 1e(36 - baseUnit)
         // Since the prices in this view have 18 decimals, we must scale them by 1e(36 - 18 - baseUnit)
        return mul(1e18, priceInternal(config)) / config.baseUnit;
    }

    /**
     * @notice Update Uniswap TWAP prices
     * @dev We let anyone pay to post anything, but only prices from Uniswap will be stored in the view.
     * @param underlyings The underlying token addresses for which to get and post TWAPs
     */
    function postPrices(address[] calldata underlyings) external {
        // Try to update the view storage
        for (uint i = 0; i < underlyings.length; i++) {
            postPriceInternal(underlyings[i]);
        }
    }

    function postPriceInternal(address underlying) internal {
        TokenConfig memory config = getTokenConfigByUnderlying(underlying);
        require(config.priceSource == PriceSource.TWAP, "only TWAP prices get posted");
        uint anchorPrice = fetchAnchorPrice(underlying, config);
        prices[underlying] = anchorPrice;
        emit PriceUpdated(underlying, anchorPrice);
    }

    /**
     * @dev Fetches the current token/eth price accumulator from uniswap.
     */
    function currentCumulativePrice(TokenConfig memory config) internal view returns (uint) {
        (uint cumulativePrice0, uint cumulativePrice1,) = UniswapV2OracleLibrary.currentCumulativePrices(config.uniswapMarket);
        if (config.isUniswapReversed) {
            return cumulativePrice1;
        } else {
            return cumulativePrice0;
        }
    }

    /**
     * @dev Fetches the current token/ETH price from Uniswap, with 18 decimals of precision.
     */
    function fetchAnchorPrice(address underlying, TokenConfig memory config) internal virtual returns (uint) {
        (uint nowCumulativePrice, uint oldCumulativePrice, uint oldTimestamp) = pokeWindowValues(config);

        // This should be impossible, but better safe than sorry
        require(block.timestamp > oldTimestamp, "now must come after before");
        uint timeElapsed = block.timestamp - oldTimestamp;

        // Calculate uniswap time-weighted average price
        // Underflow is a property of the accumulators: https://uniswap.org/audit.html#orgc9b3190
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(uint224((nowCumulativePrice - oldCumulativePrice) / timeElapsed));
        uint rawUniswapPriceMantissa = priceAverage.decode112with18();
        uint unscaledPriceMantissa = mul(rawUniswapPriceMantissa, 1e18);
        uint anchorPrice;

        // Adjust rawUniswapPrice according to the units of the non-ETH asset
        if (config.isUniswapReversed) {
            // unscaledPriceMantissa * ethBaseUnit / config.baseUnit / expScale, but we simplify bc ethBaseUnit == expScale
            anchorPrice = unscaledPriceMantissa / config.baseUnit;
        } else {
            anchorPrice = mul(unscaledPriceMantissa, config.baseUnit) / ethBaseUnit / expScale;
        }

        emit AnchorPriceUpdated(underlying, anchorPrice, oldTimestamp, block.timestamp);

        return anchorPrice;
    }

    /**
     * @dev Get time-weighted average prices for a token at the current timestamp.
     *  Update new and old observations of lagging window if period elapsed.
     */
    function pokeWindowValues(TokenConfig memory config) internal returns (uint, uint, uint) {
        address underlying = config.underlying;
        uint cumulativePrice = currentCumulativePrice(config);

        Observation memory newObservation = newObservations[underlying];

        // Update new and old observations if elapsed time is greater than or equal to anchor period
        uint timeElapsed = block.timestamp - newObservation.timestamp;
        if (timeElapsed >= anchorPeriod) {
            oldObservations[underlying].timestamp = newObservation.timestamp;
            oldObservations[underlying].acc = newObservation.acc;

            newObservations[underlying].timestamp = block.timestamp;
            newObservations[underlying].acc = cumulativePrice;
            emit UniswapWindowUpdated(config.underlying, newObservation.timestamp, block.timestamp, newObservation.acc, cumulativePrice);
        }
        return (cumulativePrice, oldObservations[underlying].acc, oldObservations[underlying].timestamp);
    }

    /// @dev Overflow proof multiplication
    function mul(uint a, uint b) internal pure returns (uint) {
        if (a == 0) return 0;
        uint c = a * b;
        require(c / a == b, "multiplication overflow");
        return c;
    }
}
