// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract BEETLE is ERC20 {
    constructor(address recipient) ERC20(unicode"🪲", unicode"🪲") {
        _mint(recipient, 1000000000 * 10 ** decimals());
    }
}