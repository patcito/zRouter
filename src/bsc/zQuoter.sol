// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @dev Multi-AMM quoter for BNB Smart Chain.
///      Quotes PancakeSwap V2 (0.25%), SushiSwap (0.3%),
///      PancakeSwap V3 (fee tiers 100/500/2500/10000),
///      Uniswap V3 (fee tiers 100/500/3000/10000) and Curve (stable/crypto-ng pools).
///      `address(0)` as tokenIn/tokenOut denotes native BNB (quoted as WBNB).
contract zQuoter {
    enum AMM {
        PCS_V2,
        SUSHI,
        PCS_V3,
        UNI_V3,
        CURVE
    }

    struct Quote {
        AMM source;
        uint256 feeBps; // V3 fee tier in bps (e.g. 25 = 0.25%); 25/30 for V2 sources; 0 for Curve
        uint256 amountIn;
        uint256 amountOut;
    }

    uint256 constant N_QUOTES = 11; // PCS_V2 + SUSHI + 4x PCS_V3 + 4x UNI_V3 + CURVE

    /// @notice Quote all supported sources for a swap. `exactOut` toggles direction.
    /// @dev Non-view (like Uniswap's QuoterV2): V3 quotes simulate real swaps whose
    ///      state changes are rolled back by the quoter callback — call offchain via eth_call.
    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        returns (Quote[] memory quotes)
    {
        quotes = new Quote[](N_QUOTES);
        unchecked {
            uint256 n;
            (uint256 aIn, uint256 aOut) = quoteV2(exactOut, tokenIn, tokenOut, swapAmount, false);
            quotes[n++] = Quote(AMM.PCS_V2, 25, aIn, aOut);
            (aIn, aOut) = quoteV2(exactOut, tokenIn, tokenOut, swapAmount, true);
            quotes[n++] = Quote(AMM.SUSHI, 30, aIn, aOut);
            for (uint256 i; i != 4; ++i) {
                uint24 fee = _pcsV3Fee(i);
                (aIn, aOut) = quoteV3(exactOut, tokenIn, tokenOut, swapAmount, fee, false);
                quotes[n++] = Quote(AMM.PCS_V3, fee / 100, aIn, aOut);
            }
            for (uint256 i; i != 4; ++i) {
                uint24 fee = _uniV3Fee(i);
                (aIn, aOut) = quoteV3(exactOut, tokenIn, tokenOut, swapAmount, fee, true);
                quotes[n++] = Quote(AMM.UNI_V3, fee / 100, aIn, aOut);
            }
            (aIn, aOut) = quoteCurve(exactOut, tokenIn, tokenOut, swapAmount);
            quotes[n++] = Quote(AMM.CURVE, 0, aIn, aOut);
        }
    }

    /// @notice Best quote across all sources. Reverts with NoQuote if none is available.
    function bestQuote(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        returns (Quote memory best)
    {
        best = _pickBest(getQuotes(exactOut, tokenIn, tokenOut, swapAmount), exactOut, false);
    }

    /// @notice Build zRouter calldata for the best *buildable* quote (V2/V3 sources).
    ///         A winning Curve quote is skipped here — Curve routes must be hand-built
    ///         via swapCurve. The returned Quote is the one the calldata was built from.
    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public returns (bytes memory callData, Quote memory best) {
        best = _pickBest(getQuotes(exactOut, tokenIn, tokenOut, swapAmount), exactOut, true);
        // A PancakeSwap winner must never receive a deadline with the venue bit set:
        // the router reads bit 255 as the SushiSwap/Uniswap V3 flag and would silently
        // swap on the wrong venue. Legacy max carries no real deadline — clamp it to a
        // 30-minute default; a packed finite deadline keeps its lower 255 bits:
        if (deadline >= ALT_VENUE) {
            if (best.source == AMM.PCS_V2 || best.source == AMM.PCS_V3) {
                deadline = deadline == type(uint256).max
                    ? block.timestamp + 30 minutes
                    : deadline & ~ALT_VENUE;
            }
        }
        if (best.source == AMM.PCS_V2 || best.source == AMM.SUSHI) {
            callData = abi.encodeCall(
                IzRouter.swapV2,
                (
                    to,
                    exactOut,
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    amountLimit,
                    // alt venues keep the caller's deadline under the venue bit:
                    best.source == AMM.SUSHI ? deadline | ALT_VENUE : deadline
                )
            );
        } else {
            // PCS_V3 or UNI_V3 (only buildable sources left):
            callData = abi.encodeCall(
                IzRouter.swapV3,
                (
                    to,
                    exactOut,
                    uint24(best.feeBps * 100),
                    tokenIn,
                    tokenOut,
                    swapAmount,
                    amountLimit,
                    best.source == AMM.UNI_V3 ? deadline | ALT_VENUE : deadline
                )
            );
        }
    }

    /// @dev Pick the winning quote. `buildableOnly` skips Curve (not encodable by buildBestSwap).
    function _pickBest(Quote[] memory quotes, bool exactOut, bool buildableOnly)
        internal
        pure
        returns (Quote memory best)
    {
        bool found;
        unchecked {
            for (uint256 i; i != quotes.length; ++i) {
                Quote memory q = quotes[i];
                if (buildableOnly && q.source == AMM.CURVE) continue;
                if (exactOut) {
                    if (q.amountIn != 0 && (!found || q.amountIn < best.amountIn)) {
                        (best, found) = (q, true);
                    }
                } else {
                    if (q.amountOut != 0 && (!found || q.amountOut > best.amountOut)) {
                        (best, found) = (q, true);
                    }
                }
            }
        }
        require(found, NoQuote());
    }

    /// @notice Constant-product quote. PCS V2 fee is 0.25% (9975/10000); Sushi 0.3% (997/1000).
    function quoteV2(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        bool sushi
    ) public view returns (uint256 amountIn, uint256 amountOut) {
        if (tokenIn == address(0)) tokenIn = WBNB;
        if (tokenOut == address(0)) tokenOut = WBNB;
        if (tokenIn == tokenOut || swapAmount == 0) return (0, 0);
        // guard the unchecked fee math below against amountIn-side overflow:
        if (swapAmount > type(uint128).max) return (0, 0);

        address pool = _v2PoolFor(tokenIn, tokenOut, sushi);
        if (!_isContract(pool)) return (0, 0);

        (bool ok, bytes memory data) =
            pool.staticcall(abi.encodeWithSelector(IV2Pool.getReserves.selector));
        if (!ok || data.length < 96) return (0, 0);
        (uint112 r0, uint112 r1,) = abi.decode(data, (uint112, uint112, uint32));
        (uint256 resIn, uint256 resOut) =
            tokenIn < tokenOut ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (resIn == 0 || resOut == 0) return (0, 0);

        (uint256 feeNum, uint256 feeDen) = sushi ? (uint256(997), 1000) : (uint256(9975), 10000);
        unchecked {
            if (exactOut) {
                amountOut = swapAmount;
                if (amountOut >= resOut) return (0, 0);
                uint256 n = resIn * amountOut * feeDen;
                uint256 d = (resOut - amountOut) * feeNum;
                amountIn = (n + d - 1) / d;
            } else {
                amountIn = swapAmount;
                amountOut = (amountIn * feeNum * resOut) / (resIn * feeDen + amountIn * feeNum);
            }
        }
    }

    /// @notice V3 quote via the onchain QuoterV2 contracts (PancakeSwap or Uniswap).
    function quoteV3(
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint24 fee,
        bool uni
    ) public returns (uint256 amountIn, uint256 amountOut) {
        if (tokenIn == address(0)) tokenIn = WBNB;
        if (tokenOut == address(0)) tokenOut = WBNB;
        if (tokenIn == tokenOut || swapAmount == 0) return (0, 0);

        address factory = uni ? UNI_V3_FACTORY : PCS_V3_FACTORY;
        address quoter = uni ? UNI_V3_QUOTER : PCS_V3_QUOTER;

        (bool ok, bytes memory data) = factory.staticcall(
            abi.encodeWithSelector(IV3Factory.getPool.selector, tokenIn, tokenOut, fee)
        );
        if (!ok || data.length < 32) return (0, 0);
        address pool = abi.decode(data, (address));
        if (pool == address(0)) return (0, 0);

        bytes memory cd = exactOut
            ? abi.encodeWithSelector(
                IQuoterV2.quoteExactOutputSingle.selector,
                IQuoterV2.QuoteExactOutputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amount: swapAmount,
                    fee: fee,
                    sqrtPriceLimitX96: 0
                })
            )
            : abi.encodeWithSelector(
                IQuoterV2.quoteExactInputSingle.selector,
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amountIn: swapAmount,
                    fee: fee,
                    sqrtPriceLimitX96: 0
                })
            );
        // plain CALL (not staticcall): QuoterV2 simulates a real swap and the pool
        // state changes must be *possible* — they are rolled back by its callback revert:
        (ok, data) = quoter.call(cd);
        if (!ok || data.length < 32) return (0, 0);
        uint256 result = abi.decode(data, (uint256));
        return exactOut ? (result, swapAmount) : (swapAmount, result);
    }

    /// @notice Curve quote across hardcoded BSC candidate pools (stable-ng & crypto-ng).
    ///         Tries int128 ABI first, then uint256 ABI. Dead/missing pools quote zero.
    ///         Exact-output note: `get_dx + 1` can underestimate by a few wei, in which
    ///         case the router's swapCurve reverts at its final slippage check — prefer
    ///         exact-in for Curve routes (documented known limitation).
    function quoteCurve(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        public
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (tokenIn == CURVE_ETH) tokenIn = address(0);
        if (tokenOut == CURVE_ETH) tokenOut = address(0);
        if (tokenIn == address(0)) tokenIn = WBNB;
        if (tokenOut == address(0)) tokenOut = WBNB;
        if (tokenIn == tokenOut || swapAmount == 0) return (0, 0);

        unchecked {
            for (uint256 p; p != 5; ++p) {
                address pool = _curvePool(p);
                if (!_isContract(pool)) continue;
                (int256 i, int256 j) = _coinIndices(pool, tokenIn, tokenOut);
                if (i < 0 || j < 0) continue;
                (uint256 aIn, uint256 aOut) = _curveQuoteOne(pool, exactOut, i, j, swapAmount);
                if (exactOut) {
                    if (aIn != 0 && (amountIn == 0 || aIn < amountIn)) {
                        (amountIn, amountOut) = (aIn, aOut);
                    }
                } else {
                    if (aOut > amountOut) (amountIn, amountOut) = (aIn, aOut);
                }
            }
        }
    }

    function _curveQuoteOne(address pool, bool exactOut, int256 i, int256 j, uint256 amount)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        bytes memory cd;
        if (exactOut) {
            // get_dx(i, j, out) -> required in:
            cd = abi.encodeWithSelector(0x67df02ca, i, j, amount); // get_dx(int128,int128,uint256)
            (bool ok, bytes memory data) = pool.staticcall(cd);
            if (!ok || data.length < 32) {
                cd = abi.encodeWithSelector(0x37ed3a7a, uint256(i), uint256(j), amount); // get_dx(uint256,uint256,uint256)
                (ok, data) = pool.staticcall(cd);
            }
            if (!ok || data.length < 32) return (0, 0);
            (amountIn, amountOut) = (abi.decode(data, (uint256)) + 1, amount);
        } else {
            // get_dy(i, j, in) -> expected out:
            cd = abi.encodeWithSelector(0x5e0d443f, i, j, amount); // get_dy(int128,int128,uint256)
            (bool ok, bytes memory data) = pool.staticcall(cd);
            if (!ok || data.length < 32) {
                cd = abi.encodeWithSelector(0x556d6e9f, uint256(i), uint256(j), amount); // get_dy(uint256,uint256,uint256)
                (ok, data) = pool.staticcall(cd);
            }
            if (!ok || data.length < 32) return (0, 0);
            (amountIn, amountOut) = (amount, abi.decode(data, (uint256)));
        }
    }

    /// @dev Find coin indices of tokenIn/tokenOut in a Curve ng pool (-1 if absent).
    function _coinIndices(address pool, address tokenIn, address tokenOut)
        internal
        view
        returns (int256 iIn, int256 jOut)
    {
        (iIn, jOut) = (-1, -1);
        unchecked {
            for (uint256 k; k != 8; ++k) {
                (bool ok, bytes memory data) =
                    pool.staticcall(abi.encodeWithSelector(0xc6610657, k)); // coins(uint256)
                if (!ok || data.length < 32) break;
                address coin = abi.decode(data, (address));
                if (coin == CURVE_ETH) coin = WBNB;
                if (coin == tokenIn) iIn = int256(k);
                if (coin == tokenOut) jOut = int256(k);
            }
        }
    }

    function _v2PoolFor(address tokenA, address tokenB, bool sushi)
        internal
        pure
        returns (address v2pool)
    {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        v2pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            sushi ? SUSHI_FACTORY : PCS_V2_FACTORY,
                            keccak256(abi.encodePacked(token0, token1)),
                            sushi ? SUSHI_POOL_INIT_CODE_HASH : PCS_V2_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    function _isContract(address a) internal view returns (bool r) {
        assembly ("memory-safe") {
            r := gt(extcodesize(a), 0)
        }
    }

    function _pcsV3Fee(uint256 i) internal pure returns (uint24 fee) {
        assembly ("memory-safe") {
            switch i
            case 0 { fee := 100 }
            case 1 { fee := 500 }
            case 2 { fee := 2500 }
            default { fee := 10000 }
        }
    }

    function _uniV3Fee(uint256 i) internal pure returns (uint24 fee) {
        assembly ("memory-safe") {
            switch i
            case 0 { fee := 100 }
            case 1 { fee := 500 }
            case 2 { fee := 3000 }
            default { fee := 10000 }
        }
    }

    /// @dev Known Curve pools on BSC (stable-ng & crypto-ng). Most Curve BSC liquidity
    ///      is long gone; quotes from dead pools simply return zero via failed staticcalls.
    function _curvePool(uint256 i) internal pure returns (address pool) {
        if (i == 0) return 0x0Fbc37F0DB1bA3AacFD0e56218f0Fb8371205d55; // stable-ng: ETH/USDT
        if (i == 1) return 0xa1174D3af66aD2fD7C6d5c7B458b6dA38988Cd56; // stable-ng: HAY/USDT/USDC
        if (i == 2) return 0xd2a1Ff5b5967c14CB1BB809fb70C0DA77C9b55A8; // stable-ng: USDT/USDC
        if (i == 3) return 0xC45B593236A994B53966Ed85Fd403b921478C2D2; // stable-ng: BTCB/rtBTC
        if (i == 4) return 0x1Fb84Fa6D252762e8367eA607A6586E09dceBe3D; // two-crypto-ng: BETH/BTCB
    }
}

error NoQuote();

interface IzRouter {
    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

interface IV2Pool {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256);
    function quoteExactOutputSingle(QuoteExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn, uint160, uint32, uint256);
}

// BSC constants:

/// @dev Bit 255 of `deadline` flags the alternate venue in the router (see zRouter).
uint256 constant ALT_VENUE = 1 << 255;

address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant CURVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

address constant PCS_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
bytes32 constant PCS_V2_POOL_INIT_CODE_HASH =
    0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5;

address constant SUSHI_FACTORY = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
bytes32 constant SUSHI_POOL_INIT_CODE_HASH =
    0xe18a34eb0e04b04f7a0ac29a6e80748dca96319b42c54d679cb821dca90c6303;

address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
address constant PCS_V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;

address constant UNI_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
address constant UNI_V3_QUOTER = 0x78D78E420Da98ad378D7799bE8f4AF69033EB077;
