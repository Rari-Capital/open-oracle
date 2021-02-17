// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "./OpenOraclePriceData.sol";
import "./Uniswap/UniswapConfig.sol";

contract ReporterView is UniswapConfig {    
    bool public constant IS_REPORTER_VIEW = true;

    /// @notice The Open Oracle Price Data contract
    OpenOraclePriceData public immutable priceData;

    /// @notice The number of wei in 1 ETH
    uint public constant ethBaseUnit = 1e18;

    /// @notice A common scaling factor to maintain precision
    uint public constant expScale = 1e18;

    /// @notice The Open Oracle Reporter
    address public immutable reporter;

    /// @notice Official prices by symbol hash
    mapping(bytes32 => uint) public prices;

    /// @notice Circuit breaker for using anchor price oracle directly, ignoring reporter
    bool public reporterInvalidated;

    /// @notice The event emitted when new prices are posted but the stored price is not updated due to the anchor
    event PriceGuarded(string symbol, uint reporter, uint anchor);

    /// @notice The event emitted when the stored price is updated
    event PriceUpdated(string symbol, uint price);

    /// @notice The event emitted when reporter invalidates itself
    event ReporterInvalidated(address reporter);

    bytes32 constant ethHash = keccak256(abi.encodePacked("ETH"));
    bytes32 constant rotateHash = keccak256(abi.encodePacked("rotate"));

    /// @dev Maps symbol hashes to token config indexes
    mapping(bytes32 => uint256) internal _configIndexesBySymbolHash;

    /// @dev Maps symbol hashes to booleans indicating if they have token configs
    mapping(bytes32 => bool) internal _configPresenceBySymbolHash;

    /**
     * @notice Construct a uniswap anchored view for a set of token configurations
     * @param priceData_ The OpenOraclePriceData contract to use
     * @param reporter_ The reporter whose prices are to be used
     * @param configs The static token configurations which define what prices are supported and how
     * @param _canAdminOverwrite Whether or not existing token configs can be overwritten
     */
    constructor(OpenOraclePriceData priceData_,
                address reporter_,
                TokenConfig[] memory configs,
                bool _canAdminOverwrite) UniswapConfig(configs, _canAdminOverwrite) public {
        // Initialize variables
        priceData = priceData_;
        reporter = reporter_;

        // Initialize token configs
        initConfigs(configs);
    }

    /**
     * @notice Initialize token configs
     * @param configs The static token configurations which define what prices are supported and how
     */
    function initConfigs(TokenConfig[] memory configs) internal {
        for (uint i = 0; i < configs.length; i++) {
            TokenConfig memory config = configs[i];
            require(config.baseUnit > 0, "baseUnit must be greater than zero");
        }
    }

    /**
     * @notice Internal function to add new asset(s)
     * @param configs The static token configurations which define what prices are supported and how
     */
    function _add(TokenConfig[] memory configs) internal {
        // For each config
        for (uint256 i = 0; i < configs.length; i++) {
            // If !canAdminOverwrite, check for existing configs
            if (!canAdminOverwrite) {
                require(!_configPresenceByUnderlying[configs[i].underlying], "Token config already exists for this underlying token address.");
                require(!_configPresenceBySymbolHash[configs[i].symbolHash], "Token config already exists for this symbol hash.");
            }

            // Add config to state
            _configs.push(configs[i]);
            _configIndexesByUnderlying[configs[i].underlying] = _configs.length - 1;
            _configPresenceByUnderlying[configs[i].underlying] = true;
            _configIndexesBySymbolHash[configs[i].underlying] = _configs.length - 1;
            _configPresenceBySymbolHash[configs[i].underlying] = true;
        }
    }

    /**
     * @notice Add new asset(s)
     * @param configs The static token configurations which define what prices are supported and how
     */
    function add(TokenConfig[] memory configs) external {
        // Check msg.sender == admin
        require(msg.sender == admin, "msg.sender is not admin");

        // Add and init token configs
        _add(configs);
        initConfigs(configs);
    }

    /**
     * @notice Get the official price for a symbol
     * @param symbol The symbol to fetch the price of
     * @return Price denominated in ETH, with 18 decimals
     */
    function price(string memory symbol) external view returns (uint) {
        TokenConfig memory config = getTokenConfigBySymbol(symbol);
        return priceInternal(config);
    }

    function priceInternal(TokenConfig memory config) internal view returns (uint) {
        if (config.symbolHash == ethHash) return ethBaseUnit;
        if (config.priceSource == PriceSource.REPORTER) {
            // Prices are stored in terms of USD so we use the ETH/USD price to convert to ETH
            uint usdPerEth = prices[ethHash];
            require(usdPerEth > 0, "ETH price not set, cannot convert from USD to ETH");
            return mul(prices[config.symbolHash], ethBaseUnit) / usdPerEth;
        }
        if (config.priceSource == PriceSource.FIXED_USD) {
            uint usdPerEth = prices[ethHash];
            require(usdPerEth > 0, "ETH price not set, cannot convert from USD to ETH");
            return mul(config.fixedPrice, ethBaseUnit) / usdPerEth;
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
        if (CToken(cToken).isCEther()) return ethBaseUnit;
        TokenConfig memory config = getTokenConfigByCToken(cToken);
         // Comptroller needs prices in the format: ${raw price} * 1e(36 - baseUnit)
         // Since the prices in this view have 18 decimals, we must scale them by 1e(36 - 18 - baseUnit)
        return mul(1e18, priceInternal(config)) / config.baseUnit;
    }

    /**
     * @notice Post open oracle reporter prices, and recalculate stored price by comparing to anchor
     * @dev We let anyone pay to post anything, but only prices from configured reporter will be stored in the view.
     * @param messages The messages to post to the oracle
     * @param signatures The signatures for the corresponding messages
     * @param symbols The symbols to compare to anchor for authoritative reading
     */
    function postPrices(bytes[] calldata messages, bytes[] calldata signatures, string[] calldata symbols) external {
        require(messages.length == signatures.length, "messages and signatures must be 1:1");

        // Save the prices
        for (uint i = 0; i < messages.length; i++) {
            priceData.put(messages[i], signatures[i]);
        }

        // Try to update the view storage
        for (uint i = 0; i < symbols.length; i++) {
            postPriceInternal(symbols[i]);
        }
    }

    function postPriceInternal(string memory symbol) internal {
        TokenConfig memory config = getTokenConfigBySymbol(symbol);
        require(config.priceSource == PriceSource.REPORTER, "only reporter prices get posted");

        bytes32 symbolHash = keccak256(abi.encodePacked(symbol));
        uint reporterPrice = priceData.getPrice(reporter, symbol);

        if (reporterInvalidated) {
            emit PriceGuarded(symbol, reporterPrice);
        } else {
            prices[symbolHash] = reporterPrice;
            emit PriceUpdated(symbol, reporterPrice);
        }
    }

    /**
     * @notice Invalidate the reporter, and fall back to using anchor directly in all cases
     * @dev Only the reporter may sign a message which allows it to invalidate itself.
     *  To be used in cases of emergency, if the reporter thinks their key may be compromised.
     * @param message The data that was presumably signed
     * @param signature The fingerprint of the data + private key
     */
    function invalidateReporter(bytes memory message, bytes memory signature) external {
        (string memory decodedMessage, ) = abi.decode(message, (string, address));
        require(keccak256(abi.encodePacked(decodedMessage)) == rotateHash, "invalid message must be 'rotate'");
        require(source(message, signature) == reporter, "invalidation message must come from the reporter");
        reporterInvalidated = true;
        emit ReporterInvalidated(reporter);
    }

    /**
     * @notice Recovers the source address which signed a message
     * @dev Comparing to a claimed address would add nothing,
     *  as the caller could simply perform the recover and claim that address.
     * @param message The data that was presumably signed
     * @param signature The fingerprint of the data + private key
     * @return The source address which signed the message, presumably
     */
    function source(bytes memory message, bytes memory signature) public pure returns (address) {
        (bytes32 r, bytes32 s, uint8 v) = abi.decode(signature, (bytes32, bytes32, uint8));
        bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(message)));
        return ecrecover(hash, v, r, s);
    }

    /// @dev Overflow proof multiplication
    function mul(uint a, uint b) internal pure returns (uint) {
        if (a == 0) return 0;
        uint c = a * b;
        require(c / a == b, "multiplication overflow");
        return c;
    }

    function getSymbolHashIndex(bytes32 symbolHash) internal view returns (uint) {
        for (uint256 i = 0; i < _configs.length; i++) if (symbolHash == _configs[i].symbolHash) return i;
        return uint(-1);
    }

    /**
     * @notice Get the config for symbol
     * @param symbol The symbol of the config to get
     * @return The config object
     */
    function getTokenConfigBySymbol(string memory symbol) public view returns (TokenConfig memory) {
        return getTokenConfigBySymbolHash(keccak256(abi.encodePacked(symbol)));
    }

    /**
     * @notice Get the config for the symbolHash
     * @param symbolHash The keccack256 of the symbol of the config to get
     * @return The config object
     */
    function getTokenConfigBySymbolHash(bytes32 symbolHash) public view returns (TokenConfig memory) {
        uint index = getSymbolHashIndex(symbolHash);
        if (index != uint(-1)) {
            return getTokenConfig(index);
        }

        revert("token config not found");
    }
}
