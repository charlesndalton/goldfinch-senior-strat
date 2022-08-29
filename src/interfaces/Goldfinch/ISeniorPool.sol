// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;

pragma experimental ABIEncoderV2;

interface ISeniorPool {
    function sharePrice() external view returns (uint256);
}