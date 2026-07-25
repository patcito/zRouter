// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title ZHubComparator (BSC)
/// @notice Exact-in route comparison across zRouter's direct and hub routes on
///         BNB Smart Chain. Port of the Ethereum ZHubComparator (see
///         patcito/zRouter branch feat/hub-comparator) to the BSC zRouter/zQuoter.
///
/// WHY THIS EXISTS. The BSC zQuoter is single-hop only: getQuotes/bestQuote/
/// buildBestSwap price direct routes across PancakeSwap V2/V3, SushiSwap,
/// Uniswap V3 and Curve, but never compare two-leg routes through hub tokens.
/// Pairs with no liquid direct pool get a bad or zero quote. This contract adds
/// the hub loop, the comparison and the multicall assembly on top of the
/// already-deployed quoter — no routing logic is duplicated.
///
/// SAFETY. There is no state beyond the two immutable addresses, no owner, no
/// token custody: it cannot hold, move or approve funds. Its only output is a
/// quote and a calldata blob for the caller to execute against zRouter, where
/// the per-leg min-out it embedded still binds. A wrong answer here can cost
/// execution quality, never principal.
///
/// NON-VIEW. Like the BSC zQuoter (and Uniswap's QuoterV2), this contract is
/// non-view because V3 quotes simulate real swaps. Call it offchain via
/// eth_call.
///
/// LEG-2 SIZING. The second leg is built with `swapAmount = 0`, zRouter's
/// auto-consume convention: the router swaps its transient credit — the output
/// leg one just delivered — rather than a number fixed at quote time, so leg two
/// cannot ask for more than leg one actually delivered and no dust is stranded.
/// (Credit-based sizing also makes the route immune to stray intermediate-token
/// balances donated to the router.)
///
/// VENUE BIT. Leg deadlines follow the BSC router's bit-packed convention:
/// bit 255 (ALT_VENUE) selects SushiSwap/Uniswap V3, the lower 255 bits stay a
/// real deadline. Callers must pass a plain timestamp (< ALT_VENUE).
///
/// Derived from zRouter (https://github.com/z-fi/zRouter), MIT, (c) 2025 z0r0z.
interface IZQuoterBSC {
    enum AMM {
        PCS_V2,
        SUSHI,
        PCS_V3,
        UNI_V3,
        CURVE
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
        uint256 amountLimit,
        uint256 deadline
    ) external returns (bytes memory callData, Quote memory best);
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

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

contract ZHubComparator {
    IZQuoterBSC public immutable QUOTER;
    address public immutable ZROUTER;

    /// @dev Bit 255 of `deadline` flags the alternate venue in the BSC router.
    uint256 internal constant ALT_VENUE = 1 << 255;

    // Hub tokens on BSC:
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address internal constant ETH_BSC = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address internal constant FDUSD = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409;

    error NoRoute();
    error InsufficientGas();

    constructor(address quoter, address zrouter) {
        require(quoter.code.length != 0 && zrouter.code.length != 0, "bad addresses");
        QUOTER = IZQuoterBSC(quoter);
        ZROUTER = zrouter;
    }

    /// @notice Best exact-in route for tokenIn -> tokenOut across the direct route
    ///         and every hub two-leg route, as executable calldata for zRouter.
    /// @param to           recipient of the output.
    /// @param tokenIn      ERC20 sold. Native BNB is not supported.
    /// @param tokenOut     ERC20 bought. Native BNB is not supported.
    /// @param amountIn     exact input amount.
    /// @param slippageBps  min-out tolerance applied per leg.
    /// @param deadline     swap deadline (plain timestamp, must be < 2**255).
    /// @return amountOut   expected output of the winning route.
    /// @return callData    send to ZROUTER. Approve ZROUTER for amountIn first.
    /// @return viaHub      true when a two-leg hub route won.
    /// @return hub         the intermediate token when viaHub, else address(0).
    /// @dev slippageBps is a CUMULATIVE budget across the whole route: each leg's
    ///      min-out = its quote * (10_000 - slippageBps) / 10_000, and leg 2's
    ///      min-out is sized from leg 1's EXPECTED output, so a hub route reverts
    ///      whenever the legs' combined slippage exceeds the budget (there is no
    ///      per-leg headroom). Route dominance over the direct route is quote-time
    ///      only — a hub route winning by less than slippageBps can deliver below
    ///      the direct *quote*, and it costs roughly twice the gas.
    function bestExactIn(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 slippageBps,
        uint256 deadline
    ) external returns (uint256 amountOut, bytes memory callData, bool viaHub, address hub) {
        require(tokenIn != address(0) && tokenOut != address(0), "native BNB unsupported");
        require(tokenIn != tokenOut, "identical tokens");
        require(amountIn != 0, "zero amount");
        require(slippageBps < 10_000, "slippage out of range");
        require(
            deadline >= block.timestamp && deadline < ALT_VENUE,
            "deadline must be a future plain timestamp"
        );

        // Direct route, quoted via the quoter's builder (which only returns
        // encodable V2/V3 sources). It may revert NoQuote — not fatal, a hub
        // route can still serve the pair.
        try QUOTER.buildBestSwap(to, false, tokenIn, tokenOut, amountIn, 0, deadline) returns (
            bytes memory, IZQuoterBSC.Quote memory q
        ) {
            if (q.amountOut != 0) {
                amountOut = q.amountOut;
                callData = _encodeLeg(to, tokenIn, tokenOut, amountIn, _limit(q.amountOut, slippageBps), deadline, q);
            }
        } catch {}

        address[6] memory hubs = [WBNB, USDT, USDC, ETH_BSC, BTCB, FDUSD];
        for (uint256 i; i < hubs.length; ++i) {
            address mid = hubs[i];
            if (mid == tokenIn || mid == tokenOut) continue;
            // fail loudly rather than silently degrading the answer when an
            // eth_call gas cap cuts the hub loop short (try/catch swallows OOG).
            // One iteration is two buildBestSwap calls ≈ 30M gas at cold-access
            // prices; require 2x headroom. Note: a full bestExactIn needs
            // ~150-350M gas — call with a raised eth_call gas cap.
            if (gasleft() < 60_000_000) revert InsufficientGas();

            (uint256 out, bytes memory cd) =
                _hubRoute(to, tokenIn, tokenOut, mid, amountIn, slippageBps, deadline);
            if (out > amountOut) {
                amountOut = out;
                callData = cd;
                viaHub = true;
                hub = mid;
            }
        }
        // an OOG swallowed in the LAST hub iteration would otherwise pass silently:
        if (gasleft() < 60_000_000) revert InsufficientGas();

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
    ) internal returns (uint256 out, bytes memory callData) {
        // Leg 1 delivers the intermediate INTO the router, so leg 2 can consume
        // it via the transient-balance chaining in multicall.
        IZQuoterBSC.Quote memory qa;
        try QUOTER.buildBestSwap(ZROUTER, false, tokenIn, mid, amountIn, 0, deadline) returns (
            bytes memory, IZQuoterBSC.Quote memory q
        ) {
            qa = q;
        } catch {
            return (0, "");
        }
        if (qa.amountOut == 0) return (0, "");

        // Leg 2 is quoted at leg 1's expected output to choose the venue and
        // price it. Only the QUOTE is kept: it is re-encoded with swapAmount = 0
        // (auto-consume) so it cannot ask for more than leg 1 delivered.
        IZQuoterBSC.Quote memory qb;
        try QUOTER.buildBestSwap(to, false, mid, tokenOut, qa.amountOut, 0, deadline) returns (
            bytes memory, IZQuoterBSC.Quote memory q
        ) {
            qb = q;
        } catch {
            return (0, "");
        }
        if (qb.amountOut == 0) return (0, "");

        bytes[] memory calls = new bytes[](2);
        calls[0] = _encodeLeg(ZROUTER, tokenIn, mid, amountIn, _limit(qa.amountOut, slippageBps), deadline, qa);
        calls[1] = _encodeLeg(to, mid, tokenOut, 0, _limit(qb.amountOut, slippageBps), deadline, qb);
        return (qb.amountOut, abi.encodeWithSelector(IZRouter.multicall.selector, calls));
    }

    /// @dev Encode one swap leg for a V2/V3 quote, packing the venue bit into
    ///      the deadline for SushiSwap/Uniswap V3 sources. `swapAmount == 0`
    ///      means the router consumes its whole balance of `tokenIn`.
    function _encodeLeg(
        address to,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline,
        IZQuoterBSC.Quote memory q
    ) internal pure returns (bytes memory) {
        if (q.source == IZQuoterBSC.AMM.PCS_V2 || q.source == IZQuoterBSC.AMM.SUSHI) {
            return abi.encodeWithSelector(
                IZRouter.swapV2.selector,
                to,
                false,
                tokenIn,
                tokenOut,
                swapAmount,
                amountLimit,
                q.source == IZQuoterBSC.AMM.SUSHI ? deadline | ALT_VENUE : deadline
            );
        }
        // PCS_V3 or UNI_V3 (CURVE is never returned by the quoter's builder):
        return abi.encodeWithSelector(
            IZRouter.swapV3.selector,
            to,
            false,
            uint24(q.feeBps * 100),
            tokenIn,
            tokenOut,
            swapAmount,
            amountLimit,
            q.source == IZQuoterBSC.AMM.UNI_V3 ? deadline | ALT_VENUE : deadline
        );
    }

    /// @dev Exact-in min-out from a quote and a bps tolerance.
    function _limit(uint256 quoted, uint256 slippageBps) internal pure returns (uint256) {
        if (slippageBps >= 10_000) return 0;
        return quoted * (10_000 - slippageBps) / 10_000;
    }
}
