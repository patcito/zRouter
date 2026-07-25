// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title ZHubComparator
/// @notice Exact-in route comparison across zRouter's direct and hub routes.
///
/// WHY THIS EXISTS. zQuoter's own `buildBestSwapViaETHMulticall` is documented to
/// compare a direct route against two-leg routes through its hubs and return
/// whichever pays more. The version DEPLOYED on Ethereum does not: it returns as
/// soon as any direct route succeeds and never evaluates its hub loop. Measured
/// on mainnet, MKR->USDC quotes 17,492,594 direct while the same builder's own
/// MKR->WETH->USDC route pays 1,335,773,497. The source that fixes this is 33,189
/// bytes of runtime and cannot be deployed (EIP-170 caps it at 24,576), which is
/// why the fix is not simply "deploy the newer quoter".
///
/// This contract restores the comparison WITHOUT redeploying any of that. It is a
/// thin, stateless view helper: every venue quote and every leg's calldata comes
/// from the already-deployed zQuoter, and all this adds is the hub loop, the
/// comparison, and the multicall assembly.
///
/// SAFETY. There is no state, no owner, no constructor arguments and no token
/// custody: it cannot hold, move or approve funds. Its only output is a quote and
/// a calldata blob for the caller to execute against zRouter, where the caller's
/// own min-out still binds. A wrong answer here can cost execution quality, never
/// principal.
///
/// LEG-2 SIZING. The second leg is built with `swapAmount = 0`, zRouter's
/// auto-consume convention: the router swaps its entire intermediate balance
/// rather than a number fixed at quote time. That is what makes a two-leg route
/// safe to assemble off-chain, since leg two cannot ask for more than leg one
/// actually delivered, and no dust is stranded. It mirrors what the newer zQuoter
/// source does for its own exact-in hub plans.
///
/// Derived from zRouter (https://github.com/z-fi/zRouter), MIT, (c) 2025 z0r0z:
/// the leg encoders and the tick-spacing map below are ports of its internal
/// `_buildSwapFromQuote`, `_buildCurveSwapCalldata` and `_spacingFromBps`, which
/// are not reachable externally.
interface IZQuoter {
    enum AMM {
        UNI_V2,
        SUSHI,
        ZAMM,
        UNI_V3,
        UNI_V4,
        CURVE,
        LIDO,
        WETH_WRAP,
        V4_HOOKED
    }

    struct Quote {
        AMM source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) external view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue);

    function quoteCurve(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, uint256 maxCandidates)
        external
        view
        returns (
            uint256 amountIn,
            uint256 amountOut,
            address bestPool,
            bool usedUnderlying,
            bool usedStable,
            uint8 iIndex,
            uint8 jIndex
        );
}

interface IZRouter {
    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256, uint256);

    function swapV3(
        address to,
        bool exactOut,
        uint24 fee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256, uint256);

    function swapV4(
        address to,
        bool exactOut,
        uint24 fee,
        int24 tickSpacing,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256, uint256);

    function swapVZ(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256, uint256);

    function swapCurve(
        address to,
        bool exactOut,
        address[11] calldata route,
        uint256[4][5] calldata swapParams,
        address[5] calldata basePools,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256, uint256);

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

contract ZHubComparator {
    IZQuoter public constant QUOTER = IZQuoter(0x0180Fe9Ae92Cd04dA670F974DE9d928EA69CfA66);
    address public constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    error NoRoute();

    /// @notice Best exact-in route for tokenIn -> tokenOut across the direct route
    ///         and every hub two-leg route, as executable calldata for zRouter.
    /// @param to           recipient of the output.
    /// @param tokenIn      ERC20 sold. Native ETH is not supported.
    /// @param tokenOut     ERC20 bought. Native ETH is not supported.
    /// @param amountIn     exact input amount.
    /// @param slippageBps  min-out tolerance applied per leg.
    /// @param deadline     swap deadline stamped into the calldata.
    /// @return amountOut   expected output of the winning route.
    /// @return callData    send to ZROUTER. Approve ZROUTER for amountIn first.
    /// @return viaHub      true when a two-leg hub route won.
    /// @return hub         the intermediate token when viaHub, else address(0).
    function bestExactIn(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        uint256 deadline
    ) external view returns (uint256 amountOut, bytes memory callData, bool viaHub, address hub) {
        require(tokenIn != address(0) && tokenOut != address(0), "native ETH unsupported");
        require(tokenIn != tokenOut, "identical tokens");
        require(amountIn != 0, "zero amount");

        // deadline == type(uint256).max is zRouter's SushiSwap sentinel in swapV2,
        // not "no expiry": passing it through would silently execute a route we
        // priced on Uniswap V2 against SushiSwap instead. Clamp to the same
        // 30-minute default the router itself substitutes, which preserves the
        // caller's intent without moving the venue. A Sushi winner still gets the
        // sentinel explicitly from the leg encoder below.
        if (deadline == type(uint256).max) deadline = block.timestamp + 30 minutes;

        // Direct route, straight from the deployed quoter. It may revert NoRoute,
        // which is not fatal: a hub route can still serve the pair.
        try QUOTER.buildBestSwap(to, false, tokenIn, tokenOut, amountIn, slippageBps, deadline) returns (
            IZQuoter.Quote memory q, bytes memory cd, uint256, uint256
        ) {
            amountOut = q.amountOut;
            callData = cd;
        } catch {}

        address[6] memory hubs = [WETH, USDC, USDT, DAI, WBTC, WSTETH];
        for (uint256 i; i < hubs.length; ++i) {
            address mid = hubs[i];
            if (mid == tokenIn || mid == tokenOut) continue;

            (uint256 out, bytes memory cd) = _hubRoute(to, tokenIn, tokenOut, mid, amountIn, slippageBps, deadline);
            if (out > amountOut) {
                amountOut = out;
                callData = cd;
                viaHub = true;
                hub = mid;
            }
        }

        if (amountOut == 0 || callData.length == 0) revert NoRoute();
    }

    /// @dev Quote and assemble tokenIn -> mid -> tokenOut. Returns (0, "") when
    ///      either leg cannot be served, so the caller simply skips this hub.
    function _hubRoute(
        address to,
        address tokenIn,
        address tokenOut,
        address mid,
        uint256 amountIn,
        uint256 slippageBps,
        uint256 deadline
    ) internal view returns (uint256 out, bytes memory callData) {
        // Leg 1 delivers the intermediate INTO the router, so leg 2 can consume
        // it. Its calldata is used verbatim.
        IZQuoter.Quote memory qa;
        bytes memory ca;
        try QUOTER.buildBestSwap(ZROUTER, false, tokenIn, mid, amountIn, slippageBps, deadline) returns (
            IZQuoter.Quote memory q, bytes memory cd, uint256, uint256
        ) {
            qa = q;
            ca = cd;
        } catch {
            return (0, "");
        }
        if (qa.amountOut == 0 || ca.length == 0) return (0, "");
        // A wrap is not a swap: it would make "hub" a relabelled direct route.
        if (qa.source == IZQuoter.AMM.WETH_WRAP || qa.source == IZQuoter.AMM.LIDO) return (0, "");

        // Leg 2 is quoted at leg 1's expected output to choose the venue and
        // price it. Only the QUOTE is kept: the returned calldata embeds a fixed
        // input amount, which would revert if leg 1 delivered a hair less.
        IZQuoter.Quote memory qb;
        try QUOTER.buildBestSwap(to, false, mid, tokenOut, qa.amountOut, slippageBps, deadline) returns (
            IZQuoter.Quote memory q, bytes memory, uint256, uint256
        ) {
            qb = q;
        } catch {
            return (0, "");
        }
        if (qb.amountOut == 0) return (0, "");
        if (qb.source == IZQuoter.AMM.WETH_WRAP || qb.source == IZQuoter.AMM.LIDO) return (0, "");

        // Rebuild leg 2 to auto-consume whatever leg 1 actually delivered.
        bytes memory cb = _buildAutoConsumeLeg(to, mid, tokenOut, qa.amountOut, _limit(qb.amountOut, slippageBps), deadline, qb);
        if (cb.length == 0) return (0, "");

        bytes[] memory calls = new bytes[](2);
        calls[0] = ca;
        calls[1] = cb;
        return (qb.amountOut, abi.encodeWithSelector(IZRouter.multicall.selector, calls));
    }

    /// @dev Encode one leg with swapAmount = 0 so zRouter consumes its whole
    ///      balance of `tokenIn`. `quotedIn` is only used to re-derive Curve pool
    ///      parameters. Returns "" for a venue we cannot encode.
    function _buildAutoConsumeLeg(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 quotedIn,
        uint256 amountLimit,
        uint256 deadline,
        IZQuoter.Quote memory q
    ) internal view returns (bytes memory) {
        if (q.source == IZQuoter.AMM.CURVE) {
            (,, address pool, bool useUnd, bool isStab, uint8 ci, uint8 cj) =
                QUOTER.quoteCurve(false, tokenIn, tokenOut, quotedIn, 8);
            if (pool == address(0)) return "";
            return _buildCurveLeg(to, tokenIn, tokenOut, amountLimit, deadline, pool, useUnd, isStab, ci, cj);
        }
        if (q.source == IZQuoter.AMM.UNI_V2 || q.source == IZQuoter.AMM.SUSHI) {
            return abi.encodeWithSelector(
                IZRouter.swapV2.selector,
                to,
                false,
                tokenIn,
                tokenOut,
                uint256(0),
                amountLimit,
                q.source == IZQuoter.AMM.SUSHI ? type(uint256).max : deadline
            );
        }
        if (q.source == IZQuoter.AMM.ZAMM) {
            return abi.encodeWithSelector(
                IZRouter.swapVZ.selector,
                to,
                false,
                q.feeBps,
                tokenIn,
                tokenOut,
                uint256(0),
                uint256(0),
                uint256(0),
                amountLimit,
                deadline
            );
        }
        if (q.source == IZQuoter.AMM.UNI_V3) {
            return abi.encodeWithSelector(
                IZRouter.swapV3.selector,
                to,
                false,
                uint24(q.feeBps * 100),
                tokenIn,
                tokenOut,
                uint256(0),
                amountLimit,
                deadline
            );
        }
        if (q.source == IZQuoter.AMM.UNI_V4) {
            return abi.encodeWithSelector(
                IZRouter.swapV4.selector,
                to,
                false,
                uint24(q.feeBps * 100),
                _spacingFromBps(uint16(q.feeBps)),
                tokenIn,
                tokenOut,
                uint256(0),
                amountLimit,
                deadline
            );
        }
        return ""; // V4_HOOKED and anything new: not encodable here.
    }

    /// @dev Single-pool Curve leg with swapAmount = 0. Mirrors zQuoter's own
    ///      encoder: route is [tokenIn, pool, tokenOut, 0…], swapParams[0] is
    ///      [i, j, swapType, poolType].
    function _buildCurveLeg(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 amountLimit,
        uint256 deadline,
        address pool,
        bool useUnderlying,
        bool isStable,
        uint8 iIndex,
        uint8 jIndex
    ) internal pure returns (bytes memory) {
        address[11] memory route;
        route[0] = tokenIn;
        route[1] = pool;
        route[2] = tokenOut;

        uint256[4][5] memory swapParams;
        swapParams[0][0] = iIndex;
        swapParams[0][1] = jIndex;
        swapParams[0][2] = (isStable && useUnderlying) ? 2 : 1;
        swapParams[0][3] = isStable ? 10 : 20;

        address[5] memory basePools;

        return abi.encodeWithSelector(
            IZRouter.swapCurve.selector, to, false, route, swapParams, basePools, uint256(0), amountLimit, deadline
        );
    }

    /// @dev Exact-in min-out. Mirrors zRouter's SlippageLib for the exactIn case.
    function _limit(uint256 quoted, uint256 slippageBps) internal pure returns (uint256) {
        if (slippageBps >= 10_000) return 0;
        return quoted * (10_000 - slippageBps) / 10_000;
    }

    /// @dev Uniswap V4 fee-to-tick-spacing map, as zQuoter defines it.
    function _spacingFromBps(uint16 bps) internal pure returns (int24) {
        unchecked {
            if (bps == 1) return 1;
            if (bps == 5) return 10;
            if (bps == 30) return 60;
            if (bps == 100) return 200;
            return int24(uint24(bps));
        }
    }
}
