// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;

interface ITradeFactory {
    function enable(address, address) external;
}