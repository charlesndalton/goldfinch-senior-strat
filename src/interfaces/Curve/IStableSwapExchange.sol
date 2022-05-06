// SPDX-License-Identifier: Copyright (c) Curve.Fi, 2021 - all rights reserved

pragma solidity ^0.8.12;

interface IStableSwapExchange {
    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);

    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
}