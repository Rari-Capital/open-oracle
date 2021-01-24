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

    /// @notice The number of tokens this contract actually supports
    uint public numTokens;

    /// @dev Token config objects
    TokenConfig[] internal _configs;

    /// @dev Maps underlying addresses to token config indexes
    mapping(address => uint256) internal _configIndexesByUnderlying;

    /// @dev Maps underlying addresses to booleans indicating if they have token configs
    mapping(address => bool) internal _configPresenceByUnderlying;
    
    /// @notice Admin address
    address public admin;

    /**
     * @notice Construct an immutable store of configs into the contract data
     * @param configs The configs for the supported assets
     */
    constructor(TokenConfig[] memory configs) public {
        admin = msg.sender;

        for (uint256 i = 0; i < configs.length; i++) {
            _configs.push(configs[i]);
            _configIndexesByUnderlying[configs[i].underlying] = i;
            _configPresenceByUnderlying[configs[i].underlying] = true;
        }

        numTokens = _configs.length;
    }

    function changeAdmin(address newAdmin) external {
        require(msg.sender == admin, "msg.sender is not admin");
        admin = newAdmin;
    }

    function getCTokenIndex(address cToken) internal view returns (uint) {
        return getUnderlyingIndex(CErc20(cToken).underlying());
    }

    function getUnderlyingIndex(address underlying) internal view returns (uint) {
        return _configPresenceByUnderlying[underlying] ? _configIndexesByUnderlying[underlying] : uint(-1);
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
