// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "../../contracts/Uniswap/UniswapView.sol";

contract MockUniswapView is UniswapView {
    mapping(address => uint) public anchorPrices;

    constructor(uint anchorPeriod_,
                TokenConfig[] memory configs) UniswapView(anchorPeriod_, configs, false, false) public {}

    function setAnchorPrice(address underlying, uint price) external {
        anchorPrices[underlying] = price;
    }

    function fetchAnchorPrice(address underlying, TokenConfig memory config) internal override returns (uint) {
        config; // Shh
        return anchorPrices[underlying];
    }
}
