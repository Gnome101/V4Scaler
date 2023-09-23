// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "hardhat/console.sol";

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

import {Call, CallType, UniswapV4Router} from "./UniswapV4Router.sol";

library UniswapV4RouterLibrary {
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;
    bytes internal constant EMPTY_RESULTS = hex"";

    /// @notice Removes the first 4 bytes from bytes data
    /// @dev Array slices only work with calldata, not memory
    function removeSelector(
        bytes calldata data
    ) internal pure returns (bytes memory remainingData) {
        require(data.length >= 4, "no selector");

        remainingData = data[4:];
    }

    function addLiquidity(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        PoolKey memory poolKey,
        address sender,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityAmount
    ) internal returns (bytes[] memory results) {
        console.log("Hi");
        Call[] memory calls = new Call[](5);

        // Add liquidity to the pool
        IPoolManager.ModifyPositionParams
            memory modifyPositionParams = IPoolManager.ModifyPositionParams(
                tickLower,
                tickUpper,
                liquidityAmount
            );
        calls[0] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                manager.modifyPosition.selector,
                poolKey,
                modifyPositionParams
            )
        });

        // Transfer token0 to Pool Manager
        bytes memory paramData = abi.encode(
            Currency.unwrap(poolKey.currency0),
            sender,
            address(manager),
            true
        );
        console.log(address(this));
        console.log("CB", callback);
        calls[1] = Call({
            target: callback,
            callType: CallType.Delegate,
            results: true,
            value: 0,
            data: abi.encodeWithSelector(
                RouterFacet.addLiquidityCallback.selector,
                paramData,
                EMPTY_RESULTS
            )
        });

        // Settle token0
        calls[2] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                manager.settle.selector,
                poolKey.currency0
            )
        });

        // Transfer token1 to Pool Manager
        paramData = abi.encode(
            Currency.unwrap(poolKey.currency1),
            sender,
            address(manager),
            false
        );
        calls[3] = Call({
            target: callback,
            callType: CallType.Delegate,
            results: true,
            value: 0,
            data: abi.encodeWithSelector(
                RouterFacet.addLiquidityCallback.selector,
                paramData,
                EMPTY_RESULTS
            )
        });

        // Settle token1
        calls[4] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                manager.settle.selector,
                poolKey.currency1
            )
        });

        results = router.process(calls);
    }

    function addLiquidityCallback(
        bytes memory callData,
        bytes memory resultData
    ) internal {
        (
            IERC20Minimal token,
            address sender,
            address recipient,
            bool zeroToken
        ) = abi.decode(callData, (IERC20Minimal, address, address, bool));

        bytes[] memory results = abi.decode(resultData, (bytes[]));
        BalanceDelta delta = abi.decode(results[0], (BalanceDelta));

        uint128 amount = zeroToken
            ? uint128(delta.amount0())
            : uint128(delta.amount1());

        require(
            token.transferFrom(sender, recipient, amount),
            "transfer failed"
        );
    }

    function removeLiquidity(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        PoolKey memory poolKey,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityAmount
    ) internal returns (bytes[] memory results) {
        Call[] memory calls = new Call[](2);

        // Add liquidity to the pool
        IPoolManager.ModifyPositionParams
            memory modifyPositionParams = IPoolManager.ModifyPositionParams(
                tickLower,
                tickUpper,
                -1 * liquidityAmount
            );
        calls[0] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                manager.modifyPosition.selector,
                poolKey,
                modifyPositionParams
            )
        });

        // Take toToken using swapCallback
        bytes memory callData = abi.encode(
            manager,
            poolKey.currency0,
            poolKey.currency1,
            recipient
        );
        bytes memory callbackData = abi.encodeWithSelector(
            RouterFacet.removeLiquidityCallback.selector,
            callData,
            EMPTY_RESULTS
        );
        calls[1] = Call({
            target: callback,
            callType: CallType.Delegate,
            results: true,
            value: 0,
            data: callbackData
        });

        results = router.process(calls);
    }

    function removeLiquidityCallback(
        bytes memory callData,
        bytes memory resultData
    ) internal {
        (
            IPoolManager poolManager,
            Currency currency0,
            Currency currency1,
            address recipient
        ) = abi.decode(callData, (IPoolManager, Currency, Currency, address));

        bytes[] memory results = abi.decode(resultData, (bytes[]));
        BalanceDelta delta = abi.decode(results[0], (BalanceDelta));

        poolManager.take(currency0, recipient, uint128(-1 * delta.amount0()));
        poolManager.take(currency1, recipient, uint128(-1 * delta.amount1()));
    }

    function swap(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        PoolKey memory poolKey,
        address swapper,
        address recipient,
        Currency fromCurrency,
        int256 swapAmount
    ) internal returns (bytes[] memory results) {
        Call[] memory calls = new Call[](4);

        bool zeroForOne = fromCurrency == poolKey.currency0;
        Currency toCurrency = zeroForOne
            ? poolKey.currency1
            : poolKey.currency0;

        // Swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        calls[0] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(manager.swap.selector, poolKey, params)
        });

        // Transfer fromToken to Pool Manager
        calls[1] = Call({
            target: Currency.unwrap(fromCurrency),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                IERC20Minimal.transferFrom.selector,
                swapper,
                address(manager),
                swapAmount
            )
        });

        // Settle fromToken
        calls[2] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(manager.settle.selector, fromCurrency)
        });

        // Take toToken using swapCallback
        bytes memory callData = abi.encode(
            manager,
            toCurrency,
            recipient,
            zeroForOne
        );
        bytes memory callbackData = abi.encodeWithSelector(
            RouterFacet.swapCallback.selector,
            callData,
            EMPTY_RESULTS
        );
        calls[3] = Call({
            target: callback,
            callType: CallType.Delegate,
            results: true,
            value: 0,
            data: callbackData
        });

        results = router.process(calls);
    }

    function swapCallback(
        bytes memory callData,
        bytes memory resultData
    ) internal {
        (
            IPoolManager poolManager,
            Currency currency,
            address recipient,
            bool zeroForOne
        ) = abi.decode(callData, (IPoolManager, Currency, address, bool));

        bytes[] memory results = abi.decode(resultData, (bytes[]));
        BalanceDelta delta = abi.decode(results[0], (BalanceDelta));

        uint128 takeAmount = zeroForOne
            ? uint128(-1 * delta.amount1())
            : uint128(-1 * delta.amount0());

        poolManager.take(currency, recipient, takeAmount);
    }

    function swapManagerTokens(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        PoolKey memory poolKey,
        Currency fromCurrency,
        int256 fromAmount,
        address recipient
    ) internal returns (bytes[] memory results) {
        Call[] memory calls = new Call[](4);

        bool zeroForOne = fromCurrency == poolKey.currency0;
        Currency toCurrency = zeroForOne
            ? poolKey.currency1
            : poolKey.currency0;

        // Swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: fromAmount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
        calls[0] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(manager.swap.selector, poolKey, params)
        });

        // Transfer ERC1155 tokens in the Pool Manager from the caller to Pool Manager using transferFromCallerToPoolManager callback
        calls[1] = Call({
            target: callback,
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                RouterFacet.transferFromCallerToPoolManager.selector,
                Currency.unwrap(fromCurrency),
                fromAmount
            )
        });

        // Settle fromToken
        calls[2] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(manager.settle.selector, fromCurrency)
        });

        // Transfer toToken using swapManagerTokensCallback
        bytes memory callData = abi.encode(
            manager,
            toCurrency,
            router,
            recipient,
            zeroForOne
        );
        bytes memory callbackData = abi.encodeWithSelector(
            RouterFacet.swapManagerTokensCallback.selector,
            callData,
            EMPTY_RESULTS
        );
        calls[3] = Call({
            target: callback,
            callType: CallType.Delegate,
            results: true,
            value: 0,
            data: callbackData
        });

        results = router.process(calls);
    }

    function swapManagerTokensCallback(
        bytes memory callData,
        bytes memory resultData
    ) internal {
        (
            IPoolManager poolManager,
            Currency currency,
            address router,
            address recipient,
            bool zeroForOne
        ) = abi.decode(
                callData,
                (IPoolManager, Currency, address, address, bool)
            );

        bytes[] memory results = abi.decode(resultData, (bytes[]));
        BalanceDelta delta = abi.decode(results[0], (BalanceDelta));

        uint128 takeAmount = zeroForOne
            ? uint128(-1 * delta.amount1())
            : uint128(-1 * delta.amount0());

        // Mint the tokens output from the swap as ERC1155 tokens in the Pool Manager
        poolManager.mint(currency, recipient, takeAmount);
    }

    /**
     * @notice Deposit tokens into the Pool Manager
     */
    function deposit(
        UniswapV4Router router,
        IPoolManager manager,
        address token,
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bytes[] memory results) {
        Call[] memory calls = new Call[](3);

        // Router transfers tokens from the spender to Pool Manager
        // This assumes the spender has approved the router to transfer the tokens
        calls[0] = Call({
            target: token,
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                IERC20Minimal.transferFrom.selector,
                sender,
                address(manager),
                amount
            )
        });

        // Mint tokens in the PoolManager and assign to the router
        calls[1] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                manager.mint.selector,
                token,
                recipient,
                amount
            )
        });

        // Settle token in the Pool Manager
        calls[2] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(manager.settle.selector, token)
        });

        results = router.process(calls);
    }

    /**
     * @notice Withdraw tokens from the Pool Manager
     */
    function withdraw(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        address token,
        address recipient,
        uint256 amount
    ) internal returns (bytes[] memory results) {
        Call[] memory calls = new Call[](2);

        // Transfer ERC1155 tokens in the Pool Manager from the caller to Pool Manager using transferFromCallerToPoolManager callback
        calls[0] = Call({
            target: callback,
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                RouterFacet.transferFromCallerToPoolManager.selector,
                token,
                amount
            )
        });

        // Take tokens from the Pool Manager
        calls[1] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                manager.take.selector,
                token,
                recipient,
                amount
            )
        });

        results = router.process(calls);
    }

    // This needs to be implemented on the callback contract. eg UniswapV4Caller
    function transferFromCallerToPoolManager(
        address token,
        uint256 amount
    ) internal {}

    function flashLoan(
        UniswapV4Router router,
        IPoolManager manager,
        address token,
        uint256 amount,
        address callbackTarget,
        CallType callbackType,
        bytes calldata callbackData
    ) internal returns (bytes[] memory results) {
        Call[] memory calls = new Call[](4);

        // borrow (take) tokens from the Pool Manager to the router
        calls[0] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                manager.take.selector,
                token,
                address(router),
                amount
            )
        });

        // Callback the specified callback function on the target contract
        calls[1] = Call({
            target: callbackTarget,
            callType: callbackType,
            results: false,
            value: 0,
            data: callbackData
        });

        // transfer tokens from this router back to the Pool Manager
        calls[2] = Call({
            target: token,
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(
                IERC20Minimal.transfer.selector,
                address(manager),
                amount
            )
        });

        // Settle the borrowed tokens with the Pool Manager
        calls[3] = Call({
            target: address(manager),
            callType: CallType.Call,
            results: false,
            value: 0,
            data: abi.encodeWithSelector(manager.settle.selector, token)
        });

        results = router.process(calls);
    }
}

contract RouterFacet {
    function removeSelector(
        bytes calldata data
    ) external pure returns (bytes memory remainingData) {
        return UniswapV4RouterLibrary.removeSelector(data);
    }

    function addLiquidity(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        PoolKey memory poolKey,
        address sender,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityAmount
    ) external returns (bytes[] memory results) {
        return
            UniswapV4RouterLibrary.addLiquidity(
                router,
                callback,
                manager,
                poolKey,
                sender,
                tickLower,
                tickUpper,
                liquidityAmount
            );
    }

    function addLiquidityCallback(
        bytes memory callData,
        bytes memory resultData
    ) external {
        UniswapV4RouterLibrary.addLiquidityCallback(callData, resultData);
    }

    function removeLiquidity(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        PoolKey memory poolKey,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityAmount
    ) external returns (bytes[] memory results) {
        return
            UniswapV4RouterLibrary.removeLiquidity(
                router,
                callback,
                manager,
                poolKey,
                recipient,
                tickLower,
                tickUpper,
                liquidityAmount
            );
    }

    function removeLiquidityCallback(
        bytes memory callData,
        bytes memory resultData
    ) external {
        UniswapV4RouterLibrary.removeLiquidityCallback(callData, resultData);
    }

    function swap(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        PoolKey memory poolKey,
        address swapper,
        address recipient,
        Currency fromCurrency,
        int256 swapAmount
    ) external returns (bytes[] memory results) {
        UniswapV4RouterLibrary.swap(
            router,
            callback,
            manager,
            poolKey,
            swapper,
            recipient,
            fromCurrency,
            swapAmount
        );
    }

    function swapCallback(
        bytes memory callData,
        bytes memory resultData
    ) external {
        UniswapV4RouterLibrary.swapCallback(callData, resultData);
    }

    function swapManagerTokens(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        PoolKey memory poolKey,
        Currency fromCurrency,
        int256 fromAmount,
        address recipient
    ) external returns (bytes[] memory results) {
        UniswapV4RouterLibrary.swapManagerTokens(
            router,
            callback,
            manager,
            poolKey,
            fromCurrency,
            fromAmount,
            recipient
        );
    }

    function swapManagerTokensCallback(
        bytes memory callData,
        bytes memory resultData
    ) external {
        UniswapV4RouterLibrary.swapManagerTokensCallback(callData, resultData);
    }

    /**
     * @notice Deposit tokens into the Pool Manager
     */
    function deposit(
        UniswapV4Router router,
        IPoolManager manager,
        address token,
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bytes[] memory results) {
        return
            UniswapV4RouterLibrary.deposit(
                router,
                manager,
                token,
                sender,
                recipient,
                amount
            );
    }

    /**
     * @notice Withdraw tokens from the Pool Manager
     */
    function withdraw(
        UniswapV4Router router,
        address callback,
        IPoolManager manager,
        address token,
        address recipient,
        uint256 amount
    ) external returns (bytes[] memory results) {
        return
            UniswapV4RouterLibrary.withdraw(
                router,
                callback,
                manager,
                token,
                recipient,
                amount
            );
    }

    // This needs to be implemented on the callback contract. eg UniswapV4Caller
    function transferFromCallerToPoolManager(
        address token,
        uint256 amount
    ) external {
        UniswapV4RouterLibrary.transferFromCallerToPoolManager(token, amount);
    }

    function flashLoan(
        UniswapV4Router router,
        IPoolManager manager,
        address token,
        uint256 amount,
        address callbackTarget,
        CallType callbackType,
        bytes calldata callbackData
    ) external returns (bytes[] memory results) {
        return
            UniswapV4RouterLibrary.flashLoan(
                router,
                manager,
                token,
                amount,
                callbackTarget,
                callbackType,
                callbackData
            );
    }
}