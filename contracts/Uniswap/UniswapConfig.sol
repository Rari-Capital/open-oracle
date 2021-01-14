// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

interface CErc20 {
    function underlying() external view returns (address);
}

contract UniswapConfig {
    /// @dev Describe how to interpret the fixedPrice in the TokenConfig.
    enum PriceSource {
        FIXED_ETH, /// implies the fixedPrice is a constant multiple of the ETH price (which varies)
        FIXED_USD, /// implies the fixedPrice is a constant multiple of the USD price (which is 1)
        REPORTER,  /// implies the price is set by the reporter (only available on UniswapAnchoredView)
        TWAP       /// implies the price is set by TWAPs (only available on UniswapView)
    }

    /// @dev Describe how the USD price should be determined for an asset.
    ///  There should be 1 TokenConfig object for each supported asset, passed in the constructor.
    struct TokenConfig {
        address underlying;
        bytes32 symbolHash;
        uint256 baseUnit;
        PriceSource priceSource;
        uint256 fixedPrice;
        address uniswapMarket;
        bool isUniswapReversed;
    }

    /// @notice The max number of tokens this contract is hardcoded to support
    /// @dev Do not change this variable without updating all the fields throughout the contract.
    uint public maxTokens;

    /// @notice The number of tokens this contract actually supports
    uint public numTokens;

    TokenConfig[] internal _configs;
    
    address public admin;

    /**
     * @notice Construct an immutable store of configs into the contract data
     * @param configs The configs for the supported assets
     */
    constructor(TokenConfig[] memory configs, uint _maxTokens) public {
        admin = msg.sender;
        maxTokens = _maxTokens;
        require(configs.length <= maxTokens, "too many configs");
        for (uint256 i = 0; i < configs.length; i++) _configs.push(configs[i]);
        numTokens = _configs.length;
    }

    function changeAdmin(address newAdmin) external {
        require(msg.sender == admin, "msg.sender is not admin");
        admin = newAdmin;
    }

    function add(TokenConfig[] memory configs) external virtual {
        require(msg.sender == admin, "msg.sender is not admin");
        require(_configs.length + configs.length <= maxTokens, "too many configs");
        for (uint256 i = 0; i < configs.length; i++) _configs.push(configs[i]);
        numTokens = _configs.length;
    }

    function getCTokenIndex(address cToken) internal view returns (uint) {
        for (uint256 i = 0; i < _configs.length; i++) if (CErc20(cToken).underlying() == _configs[i].underlying) return i;
        return uint(-1);
    }

    function getUnderlyingIndex(address underlying) internal view returns (uint) {
        for (uint256 i = 0; i < _configs.length; i++) if (underlying == _configs[i].underlying) return i;
        return uint(-1);
    }

    function getSymbolHashIndex(bytes32 symbolHash) internal view returns (uint) {
        for (uint256 i = 0; i < _configs.length; i++) if (symbolHash == _configs[i].symbolHash) return i;
        return uint(-1);
    }

    /**
     * @notice Get the i-th config, according to the order they were passed in originally
     * @param i The index of the config to get
     * @return The config object
     */
    function getTokenConfig(uint i) public view returns (TokenConfig memory) {
        require(i < numTokens, "token config not found");
        return _configs[i];
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

    /**
     * @notice Get the config for the cToken
     * @dev If a config for the cToken is not found, falls back to searching for the underlying.
     * @param cToken The address of the cToken of the config to get
     * @return The config object
     */
    function getTokenConfigByCToken(address cToken) public view returns (TokenConfig memory) {
        uint index = getCTokenIndex(cToken);
        if (index != uint(-1)) {
            return getTokenConfig(index);
        }

        return getTokenConfigByUnderlying(CErc20(cToken).underlying());
    }

    /**
     * @notice Get the config for an underlying asset
     * @param underlying The address of the underlying asset of the config to get
     * @return The config object
     */
    function getTokenConfigByUnderlying(address underlying) public view returns (TokenConfig memory) {
        uint index = getUnderlyingIndex(underlying);
        if (index != uint(-1)) {
            return getTokenConfig(index);
        }

        revert("token config not found");
    }
}
