// SPDX-License-Identifier: MIT

pragma solidity =0.7.6;

import '@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol';

contract LimitOrdersTokens is ERC1155Burnable {
    constructor() ERC1155Burnable('https://uniswap-v3-limit-orders');
}
