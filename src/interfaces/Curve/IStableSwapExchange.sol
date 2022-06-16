// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

interface IStableSwapExchange {
    function get_dy(
        uint256 i,
        uint256 j,
        uint256 dx
    ) external view returns (uint256);

    function exchange_underlying(
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);

    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount
    ) external returns (uint256);

      
}