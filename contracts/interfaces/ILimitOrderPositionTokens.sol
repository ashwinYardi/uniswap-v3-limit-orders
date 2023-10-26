// SPDX-License-Identifier: MIT

pragma solidity =0.7.6;

import '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';

interface ILimitOrderPositionTokens is IERC1155 {
    function mint(address to, uint256 id, uint256 value, bytes memory data) external;

    function burn(address account, uint256 id, uint256 value) external;

    function burnBatch(address account, uint256[] memory ids, uint256[] memory values) external;

    function totalSupply(uint256 id) external view returns (uint256);
}
