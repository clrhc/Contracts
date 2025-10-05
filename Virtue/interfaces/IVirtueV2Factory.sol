// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0 < 0.9.0;

interface IVirtueV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function tokenLaunched(address _token) external view returns(bool);
}
