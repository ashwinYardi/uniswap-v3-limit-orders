// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import '../interfaces/IUniswapV3Pool.sol';
import '../interfaces/callback/IUniswapV3MintCallback.sol';
import '../interfaces/IERC20Minimal.sol';
import '../interfaces/ILimitOrderPositionTokens.sol';
import '../interfaces/IWETH9.sol';
import '../libraries/TransferHelper.sol';

contract LimitOrdersManager is IUniswapV3MintCallback {
    uint constant SCALEUP_FACTOR = 1e36;

    ILimitOrderPositionTokens public immutable limitOrderPositionTokens;

    address public immutable token0;
    address public immutable token1;

    uint public tokenIdCounter = 0;

    mapping(uint => bytes32) public tokenIdToMetdata;

    mapping(bytes32 => LimitOrderMetadata) public orderIdToMetadata;

    mapping(int24 => uint) public tickToNonce;

    struct LimitOrderMetadata {
        uint tokenid; // Token id for LimitOrdersTokens contract
        address quoteAsset; // Token to buy
        address baseAsset; // Token to sell
        int24 tickLower;
        int24 tickUpper;
        uint256 amountBaseAssetCommitted; // Total amount of base asset committed to this order
        uint256 amountQuoteAssetReceived; // Total amount of quote asset received from this order
        bool isAboveSpotTick; // Is the order above or below the current tick
        bool isOrderFilled; // Is the order filled
        uint filledAtNonce; // The nonce at which the order was filled
        uint quoteAssetBalance; // The quote asset balance after it is received.
    }

    IUniswapV3Pool public uniswapV3Pool; // The address of your UniswapV3Pool

    int24 public immutable tickSpacing;

    address public immutable WETH9;

    modifier onlyUniswapV3Pool() {
        require(msg.sender == address(uniswapV3Pool), 'Not authorized');
        _;
    }

    constructor(address _uniswapV3Pool, address _WETH9, ILimitOrderPositionTokens _limitOrderPositionTokens) {
        WETH9 = _WETH9;
        uniswapV3Pool = IUniswapV3Pool(_uniswapV3Pool);
        tickSpacing = uniswapV3Pool.tickSpacing();
        token0 = uniswapV3Pool.token0();
        token1 = uniswapV3Pool.token1();
        limitOrderPositionTokens = _limitOrderPositionTokens;
    }

    function createLimitOrder(address recipient, int24 tick, uint128 amount) external {
        // Get the current tick and check if the order is above or below the current tick
        (, int24 currentTick, , , , , ) = uniswapV3Pool.slot0();
        require(tick != currentTick, 'Cannot add limit order to current tick');
        bool isAboveSpotTick = tick > currentTick;

        // Id Of the LimitOrderMetadata
        bytes32 orderId = keccak256(abi.encodePacked(tick, tickToNonce[tick]));

        // Get the metadata for the tick from storage.
        LimitOrderMetadata storage metadata = orderIdToMetadata[orderId];

        require(metadata.isOrderFilled == false, 'Order already filled');

        // If the first order for this id, initialize the metadata
        if (metadata.tickLower == 0 && metadata.amountBaseAssetCommitted == 0) {
            metadata.tickLower = tick;
            metadata.tickUpper = tick + tickSpacing;
            metadata.isAboveSpotTick = isAboveSpotTick;
            (metadata.quoteAsset, metadata.baseAsset) = isAboveSpotTick ? (token0, token1) : (token1, token0);
            metadata.tokenid = tokenIdCounter;
            // update the tokenId Mapping
            tokenIdToMetdata[tokenIdCounter] = orderId;
            tokenIdCounter++;
        }

        // Update the total amount commited.
        metadata.amountBaseAssetCommitted += amount;

        // Mint the ERC1155 token for the order
        limitOrderPositionTokens.mint(recipient, metadata.tokenid, amount, '');

        // Mint the position in the Uniswap V3 pool
        uniswapV3Pool.mint(
            address(this),
            tick,
            tick + tickSpacing,
            amount,
            abi.encode(msg.sender) // Limit order owner
        );
    }

    struct CollectLimitOrderStruct {
        bytes32 orderId;
        uint256 tokenId;
        uint amountToTransfer;
        address assetToTransfer;
        uint positionTokenBalance;
        uint scaledUpShares;
    }

    function collectLimitOrder(address recipent, int24 tick, uint nonce) external onlyUniswapV3Pool {
        CollectLimitOrderStruct memory collectLimitOrderStruct;
        // Get the order Ids for this tick
        collectLimitOrderStruct.orderId = keccak256(abi.encodePacked(tick, nonce));
        LimitOrderMetadata storage metadata = orderIdToMetadata[collectLimitOrderStruct.orderId];

        // Get the tokenId for this metadata
        collectLimitOrderStruct.tokenId = metadata.tokenid;
        collectLimitOrderStruct.positionTokenBalance = limitOrderPositionTokens.balanceOf(
            msg.sender,
            collectLimitOrderStruct.tokenId
        );
        collectLimitOrderStruct.scaledUpShares =
            (collectLimitOrderStruct.positionTokenBalance * SCALEUP_FACTOR) /
            limitOrderPositionTokens.totalSupply(collectLimitOrderStruct.tokenId);

        require(collectLimitOrderStruct.positionTokenBalance > 0, 'Not enough position tokens');

        if (metadata.isOrderFilled) {
            collectLimitOrderStruct.amountToTransfer =
                (metadata.amountQuoteAssetReceived * collectLimitOrderStruct.scaledUpShares) /
                SCALEUP_FACTOR;
            collectLimitOrderStruct.assetToTransfer = metadata.quoteAsset;
        } else {
            // Collect liquidity from the pool.
            // The collected amounts are now held by this contract.
            uint amount0ToCollect;
            uint amount1ToCollect;
            uint baseAssetToCollect = (metadata.amountBaseAssetCommitted * collectLimitOrderStruct.scaledUpShares) /
                SCALEUP_FACTOR;
            if (metadata.baseAsset == token0) {
                (amount0ToCollect, amount1ToCollect) = (baseAssetToCollect, 0);
            } else {
                (amount0ToCollect, amount1ToCollect) = (0, baseAssetToCollect);
            }
            (uint256 collectedAmount0, uint256 collectedAmount1) = uniswapV3Pool.collect(
                address(this),
                tick,
                tick + tickSpacing,
                uint128(amount0ToCollect), // max amount of token0
                uint128(amount1ToCollect) // max amount of token1
            );
            collectLimitOrderStruct.amountToTransfer = baseAssetToCollect;
            collectLimitOrderStruct.assetToTransfer = metadata.baseAsset;
        }
        if (
            collectLimitOrderStruct.amountToTransfer > 0 &&
            (metadata.quoteAssetBalance > 0 || metadata.amountBaseAssetCommitted > 0)
        ) {
            _pay(
                collectLimitOrderStruct.assetToTransfer,
                address(this),
                recipent,
                collectLimitOrderStruct.amountToTransfer
            );
        }
    }

    function processLimitOrdersAtTick(int24 crossedTick) external onlyUniswapV3Pool {
        // Get the order Ids for this tick
        bytes32 orderId = keccak256(abi.encodePacked(crossedTick, tickToNonce[crossedTick]));
        LimitOrderMetadata storage metadata = orderIdToMetadata[orderId];

        if (metadata.isOrderFilled) {
            return;
        }
        if (metadata.amountBaseAssetCommitted == 0) {
            return;
        }

        // Collect liquidity from the pool.
        // The collected amounts are now held by this contract.
        (uint256 collectedAmount0, uint256 collectedAmount1) = uniswapV3Pool.collect(
            address(this),
            crossedTick,
            crossedTick + tickSpacing,
            type(uint128).max, // max amount of token0
            type(uint128).max // max amount of token1
        );

        // Update the amount collected
        metadata.amountQuoteAssetReceived = metadata.quoteAsset == token0 ? collectedAmount0 : collectedAmount1;
        metadata.quoteAssetBalance = metadata.amountQuoteAssetReceived;
        metadata.isOrderFilled = true;
        metadata.filledAtNonce = tickToNonce[crossedTick];

        // increment the nonce for this tick.
        tickToNonce[crossedTick]++;
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
