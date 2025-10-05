// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPetalFactoryV2 {
    function MintWeed(uint256 amount, address recipient) external;
}

interface IPetalTokenV2 {
    function MintToken(uint256 amount, address recipient) external;
}

interface IVirtueSekai {
    function WalletTokens(address wallet) external view returns(uint[] memory);
}

contract PetalRewards is ReentrancyGuard{

    address immutable factory;
    address immutable petal;
    address immutable virtue;
    address immutable virtueSekai;
    mapping (uint => bool) claimed;
    
    constructor(address _factory, address _petal, address _virtue, address _virtueSekai){
        factory = _factory;
        petal = _petal;
        virtue = _virtue;
        virtueSekai = _virtueSekai;
    }

    function checkRewards(address _user) public view returns (uint) {
    uint[] memory tokens = IVirtueSekai(virtueSekai).WalletTokens(_user);
    uint reward = 0;
    for (uint i = 0; i < tokens.length; i++) {
        uint tokenId = tokens[i];
        if (!claimed[tokenId]) {
            reward += 1000;
        }
    }
    return reward;
}

function claimRewards() public nonReentrant {
    uint reward = checkRewards(msg.sender);
    if (reward == 0) revert();

    IPetalTokenV2(petal).MintToken(reward * 1e18, msg.sender);
    IPetalTokenV2(virtue).MintToken((reward * 30) * 1e18, msg.sender);
    IPetalFactoryV2(factory).MintWeed((reward * 30) * 1e18, msg.sender);

    uint[] memory tokens = IVirtueSekai(virtueSekai).WalletTokens(msg.sender);
    for (uint i = 0; i < tokens.length; i++) {
        uint tokenId = tokens[i];
        if (!claimed[tokenId]) {
            claimed[tokenId] = true;
        }
    }
}

}