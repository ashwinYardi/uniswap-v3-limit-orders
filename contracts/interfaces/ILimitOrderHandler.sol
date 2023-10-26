pragma solidity =0.7.6;

/// @title LimitOrdersHandler interface for UniswapV3Pool file.
/// @notice Contains a subset of the full LimitOrdersHandler interface that is used in Uniswap V3 Pool file after the tick has been cross for each swap.
interface ILimitOrderHandler {
    function processLimitOrdersAtTick(int24 crossedTick) external;
}
