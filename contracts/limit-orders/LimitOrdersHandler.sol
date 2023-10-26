// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import '../interfaces/IUniswapV3Pool.sol';
import '../interfaces/callback/IUniswapV3MintCallback.sol';
import '../interfaces/IERC20Minimal.sol';
import '../interfaces/ILimitOrderPositionTokens.sol';
import '../interfaces/IWETH9.sol';

import '../libraries/TransferHelper.sol';

import '../limit-orders-position-tokens/PositionTokensDeployer.sol';

/**
 * @title LimitOrdersHandler
 * @author Ashwin Yardi
 * @notice This contract handles limit orders for Uniswap V3.
 * These Limit orders are nothing but the Range orders on top of Uniswap V3 pool.
 * Users can create Limit Orders. Each Limit Order is represented by 'unique' tokenId in the LimitOrderPositionTokens collection.
 * When Limit orders are created, users receives ERC-1155 tokens of resp tokenId where amount = amountBaseAssetCommitted.
 * In the context of the Uniswap, each LimtiOrder is nothing but the Single Positon opened by this contract.
 * So total supply of ERC-1155 tokens and balance of ERC-1155 tokens of user is used to calculate the share of the Positon.
 */
contract LimitOrdersHandler is IUniswapV3MintCallback, PositionTokensDeployer {
    uint constant SCALEUP_FACTOR = 1e36; // Used for precision

    ILimitOrderPositionTokens public immutable limitOrderPositionTokens;

    address public immutable token0;
    address public immutable token1;

    uint public tokenIdCounter = 0;

    // LimitOrder = Position on Uniswap V3. So this Struct tracks the metadata of the position and thereby the limit order.
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

    // Mapping to track the OrderId associated with a tokenId.
    mapping(uint => bytes32) public tokenIdTOrderId;

    // Mapping to track the LimitOrderMetadata associated with a orderId.

    mapping(bytes32 => LimitOrderMetadata) public orderIdToMetadata;

    // This mapping tracks the nonce for the limit order associated with each tick. This makes "multiple" limit orders at the same tick possible.
    // OrderId = keccak256(abi.encodePacked(tick, tickToNonce[tick]))
    mapping(int24 => uint) public tickToNonce;

    IUniswapV3Pool public uniswapV3Pool; // The address of your UniswapV3Pool

    int24 public immutable tickSpacing;

    // WETH9 address used by Uniswap V3
    address public immutable WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    modifier onlyUniswapV3Pool() {
        require(msg.sender == address(uniswapV3Pool), 'Not authorized');
        _;
    }

    /**
     * @dev Constructor
     * @param _uniswapV3Pool The address of your UniswapV3Pool
     * @notice The constructor deploys the LimitOrderPositionTokens Collection.
     */
    constructor(address _uniswapV3Pool) {
        uniswapV3Pool = IUniswapV3Pool(_uniswapV3Pool);
        tickSpacing = uniswapV3Pool.tickSpacing();
        token0 = uniswapV3Pool.token0();
        token1 = uniswapV3Pool.token1();
        limitOrderPositionTokens = ILimitOrderPositionTokens(_deployFromBytecode(POSITTION_TOKENS_BYTECODE));
    }

    /**
     * @dev Create a Limit Order
     * @param recipient The address of the recipient of the limit order.
     * @param tick The tick at which the limit order is to be created.
     * @param amount The amount of base asset to be committed to the limit order.
     * @return orderId The ID of the created limit order
     */
    function createLimitOrder(address recipient, int24 tick, uint128 amount) external returns (bytes32 orderId) {
        // Get the current tick and check if the order is above or below the current tick
        (, int24 currentTick, , , , , ) = uniswapV3Pool.slot0();
        require(tick != currentTick, 'Cannot add limit order to current tick');
        bool isAboveSpotTick = tick > currentTick;

        // Id Of the LimitOrderMetadata
        orderId = keccak256(abi.encodePacked(tick, tickToNonce[tick]));

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
            tokenIdTOrderId[tokenIdCounter] = orderId;
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

    // Trasient Memory storage required for collectLimitOrder function.
    //TODO: Pack this struct.
    struct CollectLimitOrderStruct {
        bytes32 orderId;
        uint256 tokenId;
        uint amountToTransfer;
        address assetToTransfer;
        uint positionTokenBalance;
        uint scaledUpShares;
    }

    /**
     * @notice Collects a limit order from the specified recipient for a given tick and nonce.
     * @dev If user calls this function after order is filled, it gives quote asset. Else it gives base asset by removing the liquidity.
     * @param recipient The address of the recipient of the limit order.
     * @param tick The tick value associated with the limit order.
     * @param nonce The nonce value associated with the limit order.
     */

    function collectLimitOrder(address recipient, int24 tick, uint nonce) external {
        CollectLimitOrderStruct memory collectLimitOrderStruct;

        // Get the order Ids for this tick
        collectLimitOrderStruct.orderId = keccak256(abi.encodePacked(tick, nonce));

        // Get the metadata
        LimitOrderMetadata storage metadata = orderIdToMetadata[collectLimitOrderStruct.orderId];

        // Get the tokenId for this metadata
        collectLimitOrderStruct.tokenId = metadata.tokenid;

        // For collecting the limit order, msg.sender should have the balance of the position tokens. If not, that means you cannot close the position.
        collectLimitOrderStruct.positionTokenBalance = limitOrderPositionTokens.balanceOf(
            msg.sender,
            collectLimitOrderStruct.tokenId
        );

        // Based on the position token balance, calculate the scaled up shares
        collectLimitOrderStruct.scaledUpShares =
            (collectLimitOrderStruct.positionTokenBalance * SCALEUP_FACTOR) /
            limitOrderPositionTokens.totalSupply(collectLimitOrderStruct.tokenId);

        // Shares should be non zero. Otherwise, you dont get anything from the pool.
        require(collectLimitOrderStruct.scaledUpShares > 0, 'Not enough position tokens');

        // Collect the liquidity from the Uniswap V3 pool
        if (metadata.isOrderFilled) {
            // If the order is filled, that means user will get the quote asset.
            collectLimitOrderStruct.amountToTransfer =
                (metadata.amountQuoteAssetReceived * collectLimitOrderStruct.scaledUpShares) /
                SCALEUP_FACTOR;
            collectLimitOrderStruct.assetToTransfer = metadata.quoteAsset;
        } else {
            // If the order is not filled, that means user will get the base asset. USer is essentially withdrawing the order before its filled.
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

        // Now whether its a baseAsset or quoteAsset, transfer the apt amount to recipient.
        if (
            collectLimitOrderStruct.amountToTransfer > 0 &&
            (metadata.quoteAssetBalance > 0 || metadata.amountBaseAssetCommitted > 0)
        ) {
            _pay(
                collectLimitOrderStruct.assetToTransfer,
                address(this),
                recipient,
                collectLimitOrderStruct.amountToTransfer
            );
        }
    }

    /**
     * @notice Processes limit orders at a given tick
     * @param crossedTick The tick crossed by the swap function.
     * @dev Only UniswapV3Pool can call this function.
     */
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

    /**
     * @dev Creates a new child contract with the given bytecode
     */
    function _deployFromBytecode(bytes memory bytecode) internal returns (address) {
        address child;
        assembly {
            mstore(0x0, bytecode)
            child := create(0, 0xa0, calldatasize())
        }
        return child;
    }
}
