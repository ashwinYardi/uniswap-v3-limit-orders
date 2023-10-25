// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IUniswapV3Pool.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './libraries/TransferHelper.sol';

contract LimitOrdersManager is IUniswapV3MintCallback {

    uint constant SCALEUP_FACTOR = 1e36;

    struct TickLiquidity {
        uint128 totalAmount0;
        uint128 totalAmount1;
        mapping(address => uint128) userAmounts0;
        mapping(address => uint128) userAmounts1;
        // Store proportionate shares
        mapping(address => uint128) userShares0;
        mapping(address => uint128) userShares1;
    }

    mapping(int24 => TickLiquidity) public tickLiquidityByTick;

    IUniswapV3Pool public uniswapV3Pool; // The address of your UniswapV3Pool

    int24 public immutable override tickSpacing;

    address public immutable override WETH9;

    modifier onlyUniswapV3Pool() {
        require(msg.sender == uniswapV3Pool, 'Not authorized');
        _;
    }

    constructor(address _uniswapV3Pool, address _WETH9) {
        uniswapV3Pool = IUniswapV3Pool(_uniswapV3Pool);
        tickSpacing = uniswapV3Pool.tickSpacing();
        WETH9 = _WETH9;
    }

    function addLimitOrder(int24 tick, uint128 amount) external {
        TickLiquidity storage tickLiq = tickLiquidityByTick[tick];

        (, int24 currentTick, , , , , ) = uniswapV3Pool.slot0();

        // Determine which token the user is selling based on the tick
        address tokenToSell;
        address tokenToBuy;

        require(tick != currentTick, 'Cannot add limit order to current tick');

        if (tick > currentTick) {
            tokenToSell = token1;
            tokenToBuy = token0;
        } else {
            tokenToSell = token0;
            tokenToBuy = token1;
        }

        tickLiq.userShares0[msg.sender] = (amount0 * SCALEUP_FACTOR) / tickLiq.totalAmount0;
        tickLiq.userShares1[msg.sender] = (amount1 * SCALEUP_FACTOR) / tickLiq.totalAmount1;

        // Update user balance for the token they're selling
        tickLiq.userAmounts[tokenToSell][msg.sender] += amount;

        // Define the tick range for the limit order
        int24 tickLower;
        int24 tickUpper;

        if (tokenToSell == token1) {
            tickLiq.token1TotalAmount += amount;
        } else {
            tickLiq.token0TotalAmount += amount;
        }

        (tickLower, tickUpper) = (tick, tick + tickSpacing);

        // Mint the position in the Uniswap V3 pool
        v3Pool.mint(
            address(this),
            tickLower,
            tickUpper,
            amount,
            abi.encode(msg.sender) // Limit order owner
        );
    }

    function collectOrder(int24 tick) external onlyUniswapV3Pool {}

    function processLimitOrdersAtTick(int24 crossedTick) external onlyUniswapV3Pool {
        TickLiquidity storage tickLiq = tickLiquidityByTick[tick];

        if (tickLiq.totalAmount == 0) {
            return;
        }

        // Collect liquidity from the pool.
        // The collected amounts are now held by this contract.
        (uint256 collectedAmount0, uint256 collectedAmount1) = v3Pool.collect(
            address(this),
            tick,
            tick + tickSpacing,
            type(uint128).max, // max amount of token0
            type(uint128).max // max amount of token1
        );

        // Here you could emit an event to log the collected amounts, if needed.

        // Reset the total liquidity at this tick
        tickLiq.token0TotalAmount = 0;
        tickLiq.token1TotalAmount = 0;
    }

    /// @inheritdoc IUniswapV3MintCallback
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override onlyUniswapV3Pool {
        address payer = abi.decode(data, (address));

        require(amount0Owed > 0 || amount1Owed > 0, 'No amount to pay');
        require(payer != address(0), 'No payer');

        if (amount0Owed > 0) _pay(token0, payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) _pay(token1, payer, msg.sender, amount1Owed);
    }

    function _pay(address token, address payer, address recipient, uint256 value) internal {
        if (token == WETH9 && address(this).balance >= value) {
            // pay with WETH9
            IWETH9(WETH9).deposit{value: value}(); // wrap only what is needed to pay
            IWETH9(WETH9).transfer(recipient, value);
        } else if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            TransferHelper.safeTransfer(token, recipient, value);
        } else {
            // pull payment
            TransferHelper.safeTransferFrom(token, payer, recipient, value);
        }
    }
}
