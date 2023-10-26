// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import './ERC1155.sol';

// This token is very basic token wit mint function open.
// Ideally, we should hae role based access control with MINTER ROLE.
contract LimitOrderPositionTokens is ERC1155 {
    constructor() ERC1155('https://uniswap-v3-limit-orders') {}

    mapping(uint256 => uint256) private _totalSupply;
    uint256 private _totalSupplyAll;

    /**
     * @dev Total value of tokens in with a given id.
     */
    function totalSupply(uint256 id) public view virtual returns (uint256) {
        return _totalSupply[id];
    }

    /**
     * @dev Total value of tokens.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupplyAll;
    }

    /**
     * @dev Indicates whether any token exist with a given id, or not.
     */
    function exists(uint256 id) public view virtual returns (bool) {
        return totalSupply(id) > 0;
    }

    /**
     * @dev See {ERC1155-_update}.
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal virtual override {
        super._update(from, to, ids, values);

        if (from == address(0)) {
            uint256 totalMintValue = 0;
            for (uint256 i = 0; i < ids.length; ++i) {
                uint256 value = values[i];
                // Overflow check required: The rest of the code assumes that totalSupply never overflows
                _totalSupply[ids[i]] += value;
                totalMintValue += value;
            }
            // Overflow check required: The rest of the code assumes that totalSupplyAll never overflows
            _totalSupplyAll += totalMintValue;
        }

        if (to == address(0)) {
            uint256 totalBurnValue = 0;
            for (uint256 i = 0; i < ids.length; ++i) {
                uint256 value = values[i];

                // Overflow not possible: values[i] <= balanceOf(from, ids[i]) <= totalSupply(ids[i])
                _totalSupply[ids[i]] -= value;
                // Overflow not possible: sum_i(values[i]) <= sum_i(totalSupply(ids[i])) <= totalSupplyAll
                totalBurnValue += value;
            }

            // Overflow not possible: totalBurnValue = sum_i(values[i]) <= sum_i(totalSupply(ids[i])) <= totalSupplyAll
            _totalSupplyAll -= totalBurnValue;
        }
    }

    function mint(address to, uint256 id, uint256 value, bytes memory data) external {
        _mint(to, id, value, data);
    }

    function burn(address account, uint256 id, uint256 value) public virtual {
        require(
            account == _msgSender() || isApprovedForAll(account, _msgSender()),
            'ERC1155: caller is not owner nor approved'
        );

        _burn(account, id, value);
    }

    function burnBatch(address account, uint256[] memory ids, uint256[] memory values) public virtual {
        require(
            account == _msgSender() || isApprovedForAll(account, _msgSender()),
            'ERC1155: caller is not owner nor approved'
        );

        _burnBatch(account, ids, values);
    }
}
