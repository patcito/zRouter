// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console2} from "@forge/Test.sol";
import {zRouter} from "../src/bsc/zRouter.sol";
import {zQuoter} from "../src/bsc/zQuoter.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IChainlink {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}

/// @dev BSC fork tests: swaps + quotes vs Chainlink reference prices.
contract zRouterBSCTest is Test {
    zRouter router;
    zQuoter quoter;

    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant ETH_BSC = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant CURVE_HAY_POOL = 0xa1174D3af66aD2fD7C6d5c7B458b6dA38988Cd56;

    address constant WHALE = 0x8894E0a0c962CB723c1976a4421c95949bE2D4E3; // binance hot wallet

    address constant CL_BNB_USD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address constant CL_ETH_USD = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e;
    address constant CL_BTC_USD = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;

    uint256 constant TOL_BPS = 500; // 5% tolerance vs Chainlink
    uint256 constant ALT_VENUE = 1 << 255; // venue flag bit (matches router/quoter)

    address USER = makeAddr("USER");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc"), 111_979_470); // pinned: price-dependent asserts
        router = new zRouter();
        quoter = new zQuoter();
        vm.deal(USER, 1000 ether);
        vm.deal(address(this), 1000 ether); // pays {value:} on pranked calls
        vm.startPrank(WHALE);
        IERC20(USDT).transfer(USER, 1_000_000 ether); // BSC stables are 18 decimals
        IERC20(USDC).transfer(USER, 1_000_000 ether);
        IERC20(ETH_BSC).transfer(USER, 100 ether);
        IERC20(BTCB).transfer(USER, 10 ether);
        vm.stopPrank();
        vm.startPrank(USER);
        IERC20(USDT).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        IERC20(ETH_BSC).approve(address(router), type(uint256).max);
        IERC20(BTCB).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ── swaps ────────────────────────────────────────────────

    function testV2_ExactIn_BNBtoUSDT() public {
        (, uint256 quoted) = quoter.quoteV2(false, address(0), USDT, 5 ether, false);
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) = router.swapV2{value: 5 ether}(
            USER, false, address(0), USDT, 5 ether, 0, block.timestamp + 1000
        );
        assertEq(amountIn, 5 ether);
        assertEq(IERC20(USDT).balanceOf(USER), 1_000_000 ether + amountOut);
        assertEq(quoted, amountOut); // router math == quoter math
        console2.log("PCS V2  5 BNB -> USDT:", amountOut / 1e18);
    }

    function testV2_ExactOut_BNBtoUSDT() public {
        (uint256 quotedIn,) = quoter.quoteV2(true, address(0), USDT, 1000 ether, false);
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) = router.swapV2{value: 20 ether}(
            USER, true, address(0), USDT, 1000 ether, 20 ether, block.timestamp + 1000
        );
        assertEq(amountOut, 1000 ether);
        assertLe(amountIn, 20 ether);
        assertEq(quotedIn, amountIn);
        console2.log("PCS V2  BNB -> 1000 USDT exact-out, BNB in:", amountIn);
    }

    function testV2_ExactIn_USDTtoBNB() public {
        uint256 balBefore = USER.balance;
        vm.prank(USER);
        (, uint256 amountOut) =
            router.swapV2(USER, false, USDT, address(0), 1000 ether, 0, block.timestamp + 1000);
        assertEq(USER.balance, balBefore + amountOut);
        console2.log("PCS V2  1000 USDT -> BNB:", amountOut);
    }

    function testV2_ExactIn_Sushi_BNBtoUSDT() public {
        (, uint256 quoted) = quoter.quoteV2(false, address(0), USDT, 0.5 ether, true);
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) = router.swapV2{value: 0.5 ether}(
            USER,
            false,
            address(0),
            USDT,
            0.5 ether,
            0,
            type(uint256).max // sushi sentinel
        );
        assertEq(amountIn, 0.5 ether);
        assertGt(amountOut, 0);
        assertEq(quoted, amountOut);
        console2.log("SUSHI   0.5 BNB -> USDT:", amountOut / 1e18);
    }

    function testV2_ExactIn_Sushi_PackedDeadline() public {
        uint256 packed = ALT_VENUE | (block.timestamp + 1000);
        (, uint256 quoted) = quoter.quoteV2(false, address(0), USDT, 0.5 ether, true);
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) = router.swapV2{value: 0.5 ether}(
            USER, false, address(0), USDT, 0.5 ether, 0, packed
        );
        assertEq(amountIn, 0.5 ether);
        assertEq(amountOut, quoted); // venue = sushi, finite deadline honored
    }

    function testV2_Sushi_PackedExpired_Reverts() public {
        uint256 packed = ALT_VENUE | (block.timestamp - 1);
        vm.prank(USER);
        vm.expectRevert(zRouter.Expired.selector); // packed deadlines are really enforced
        router.swapV2{value: 0.5 ether}(USER, false, address(0), USDT, 0.5 ether, 0, packed);
    }

    function testV3_ExactIn_ETHtoUSDT_UNI_PackedDeadline() public {
        uint256 packed = ALT_VENUE | (block.timestamp + 1000);
        (, uint256 uniQuoted) = quoter.quoteV3(false, ETH_BSC, USDT, 1 ether, 500, true);
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV3(USER, false, 500, ETH_BSC, USDT, 1 ether, 0, packed);
        assertEq(amountIn, 1 ether);
        assertEq(amountOut, uniQuoted); // venue = uni v3, finite deadline honored
    }

    function testV3_UNI_PackedExpired_Reverts() public {
        uint256 packed = ALT_VENUE | (block.timestamp - 1);
        vm.prank(USER);
        vm.expectRevert(zRouter.Expired.selector);
        router.swapV3(USER, false, 500, ETH_BSC, USDT, 1 ether, 0, packed);
    }

    /// @dev deadline == ALT_VENUE decodes to 0 → instantly Expired (no flag-only call).
    function testV2_PackedZeroDeadline_Reverts() public {
        vm.prank(USER);
        vm.expectRevert(zRouter.Expired.selector);
        router.swapV2{value: 0.5 ether}(USER, false, address(0), USDT, 0.5 ether, 0, ALT_VENUE);
    }

    /// @dev deadline == ALT_VENUE - 1 has the venue bit clear → PancakeSwap, no expiry.
    function testV2_JustBelowVenueBit_StaysPCS() public {
        (, uint256 quoted) = quoter.quoteV2(false, address(0), USDT, 5 ether, false);
        vm.prank(USER);
        (, uint256 amountOut) = router.swapV2{value: 5 ether}(
            USER, false, address(0), USDT, 5 ether, 0, ALT_VENUE - 1
        );
        assertEq(amountOut, quoted);
    }

    /// @dev A finite packed deadline into buildBestSwap with a PCS winner must
    ///      round-trip: venue bit stripped, caller's timestamp preserved.
    function testBuildBestSwap_PackedDeadline_PCS_RoundTrips() public {
        uint256 ts = block.timestamp + 300;
        (bytes memory cd, zQuoter.Quote memory best) =
            quoter.buildBestSwap(USER, false, address(0), USDT, 1 ether, 0, ALT_VENUE | ts);
        assertTrue(best.source != zQuoter.AMM.CURVE);
        bytes memory args = new bytes(cd.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = cd[i + 4];
        }
        uint256 encodedDeadline;
        if (best.source == zQuoter.AMM.PCS_V2 || best.source == zQuoter.AMM.SUSHI) {
            (,,,,,, encodedDeadline) =
                abi.decode(args, (address, bool, address, address, uint256, uint256, uint256));
        } else {
            (,,,,,,, encodedDeadline) = abi.decode(
                args, (address, bool, uint24, address, address, uint256, uint256, uint256)
            );
        }
        bool isPcs = best.source == zQuoter.AMM.PCS_V2 || best.source == zQuoter.AMM.PCS_V3;
        if (isPcs) {
            assertEq(encodedDeadline, ts, "PCS winner must keep the caller's finite deadline");
        } else {
            assertEq(encodedDeadline, ts | ALT_VENUE, "alt venue must repack the deadline");
        }
        // and it must execute:
        uint256 balBefore = IERC20(USDT).balanceOf(USER);
        vm.prank(USER);
        (bool ok,) = address(router).call{value: 1 ether}(cd);
        assertTrue(ok, "built swap failed");
        assertEq(IERC20(USDT).balanceOf(USER) - balBefore, best.amountOut);
    }

    function testV3_ExactIn_ETHtoUSDT_PCS() public {
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV3(USER, false, 500, ETH_BSC, USDT, 1 ether, 0, block.timestamp + 1000);
        assertEq(amountIn, 1 ether);
        assertGt(amountOut, 0);
        console2.log("PCS V3  1 ETH -> USDT:", amountOut / 1e18);
    }

    function testV3_ExactIn_ETHtoUSDT_UNI() public {
        (, uint256 uniQuoted) = quoter.quoteV3(false, ETH_BSC, USDT, 1 ether, 500, true);
        (, uint256 pcsQuoted) = quoter.quoteV3(false, ETH_BSC, USDT, 1 ether, 500, false);
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) = router.swapV3(
            USER,
            false,
            500,
            ETH_BSC,
            USDT,
            1 ether,
            0,
            type(uint256).max // uni sentinel
        );
        assertEq(amountIn, 1 ether);
        assertGt(amountOut, 0);
        // pin the venue: result must match the Uniswap quote, not the PancakeSwap one
        assertEq(amountOut, uniQuoted);
        assertNotEq(uniQuoted, pcsQuoted);
        console2.log("UNI V3  1 ETH -> USDT:", amountOut / 1e18);
    }

    function testV3_ExactOut_USDTtoBTCB_PCS() public {
        uint256 balBefore = IERC20(BTCB).balanceOf(USER);
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) = router.swapV3(
            USER, true, 500, USDT, BTCB, 0.01 ether, 1000 ether, block.timestamp + 1000
        );
        assertEq(amountOut, 0.01 ether);
        assertEq(IERC20(BTCB).balanceOf(USER), balBefore + 0.01 ether);
        console2.log("PCS V3  USDT -> 0.01 BTCB exact-out, USDT in:", amountIn / 1e18);
    }

    function testV3_ExactIn_WBNBtoUSDT_PCS() public {
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) = router.swapV3{value: 2 ether}(
            USER, false, 2500, address(0), USDT, 2 ether, 0, block.timestamp + 1000
        );
        assertEq(amountIn, 2 ether);
        assertGt(amountOut, 0);
        console2.log("PCS V3  2 BNB -> USDT (2500 tier):", amountOut / 1e18);
    }

    function testSwapCurve_USDTtoUSDC() public {
        address[11] memory route;
        route[0] = USDT;
        route[1] = CURVE_HAY_POOL; // stable-ng HAY/USDT/USDC
        route[2] = USDC;
        uint256[4][5] memory params;
        params[0] = [uint256(1), uint256(2), uint256(1), uint256(10)]; // i, j, exchange, stable-ng
        address[5] memory basePools;
        vm.prank(USER);
        (uint256 amountIn, uint256 amountOut) = router.swapCurve(
            USER, false, route, params, basePools, 1 ether, 0, block.timestamp + 1000
        );
        assertEq(amountIn, 1 ether);
        assertGt(amountOut, 0.9 ether); // stable swap ~1:1
        console2.log("CURVE   1 USDT -> USDC:", amountOut);
    }

    // ── quotes vs chainlink ──────────────────────────────────

    function testQuotes_BNB_USDT() public {
        zQuoter.Quote memory best = quoter.bestQuote(false, address(0), USDT, 10 ether);
        uint256 expected = (10 ether * uint256(IChainlink(CL_BNB_USD).latestAnswer())) / 1e8;
        _logQuotes(false, address(0), USDT, 10 ether);
        console2.log("BEST 10 BNB -> USDT:", best.amountOut / 1e18, "src:", uint8(best.source));
        console2.log("chainlink expected   :", expected / 1e18);
        assertGt(best.amountOut, 0);
        assertApproxEqRel(best.amountOut, expected, TOL_BPS * 1e14); // 5%
    }

    function testQuotes_ETH_USDT() public {
        zQuoter.Quote memory best = quoter.bestQuote(false, ETH_BSC, USDT, 1 ether);
        uint256 expected = uint256(IChainlink(CL_ETH_USD).latestAnswer()) * 1e10; // 8->18 dec
        _logQuotes(false, ETH_BSC, USDT, 1 ether);
        console2.log("BEST 1 ETH -> USDT:", best.amountOut / 1e18, "src:", uint8(best.source));
        console2.log("chainlink expected :", expected / 1e18);
        assertGt(best.amountOut, 0);
        assertApproxEqRel(best.amountOut, expected, TOL_BPS * 1e14);
    }

    function testQuotes_BTC_USDT() public {
        zQuoter.Quote memory best = quoter.bestQuote(false, BTCB, USDT, 0.1 ether);
        uint256 expected = uint256(IChainlink(CL_BTC_USD).latestAnswer()) * 1e10 / 10;
        _logQuotes(false, BTCB, USDT, 0.1 ether);
        console2.log("BEST 0.1 BTCB -> USDT:", best.amountOut);
        console2.log("chainlink expected    :", expected);
        assertGt(best.amountOut, 0);
        assertApproxEqRel(best.amountOut, expected, TOL_BPS * 1e14);
    }

    function testQuotes_ExactOut_BNB_USDT() public {
        zQuoter.Quote memory best = quoter.bestQuote(true, address(0), USDT, 1000 ether);
        uint256 expectedBnb = (1000 ether * 1e8) / uint256(IChainlink(CL_BNB_USD).latestAnswer());
        console2.log("BEST BNB in for 1000 USDT:", best.amountIn, "src:", uint8(best.source));
        console2.log("chainlink expected BNB    :", expectedBnb);
        assertGt(best.amountIn, 0);
        assertApproxEqRel(best.amountIn, expectedBnb, TOL_BPS * 1e14);
    }

    function testBuildBestSwap_BNBtoUSDT() public {
        (bytes memory cd, zQuoter.Quote memory best) =
            quoter.buildBestSwap(USER, false, address(0), USDT, 1 ether, 0, block.timestamp + 1000);
        uint256 balBefore = IERC20(USDT).balanceOf(USER);
        vm.prank(USER);
        (bool ok,) = address(router).call{value: 1 ether}(cd);
        assertTrue(ok, "built swap failed");
        uint256 got = IERC20(USDT).balanceOf(USER) - balBefore;
        assertEq(got, best.amountOut); // execution matches quote exactly
        console2.log("buildBestSwap 1 BNB -> USDT:", got / 1e18, "src:", uint8(best.source));
    }

    // ── regression tests for review findings ─────────────────

    /// @dev buildBestSwap must clamp a caller's deadline==max when the winner is
    ///      PancakeSwap — otherwise the router reads it as the Sushi/Uni sentinel.
    function testBuildBestSwap_DeadlineSentinelClamped() public {
        (bytes memory cd, zQuoter.Quote memory best) =
            quoter.buildBestSwap(USER, false, address(0), USDT, 1 ether, 0, type(uint256).max);
        assertTrue(best.source != zQuoter.AMM.CURVE);
        // decode the deadline (last arg of swapV2/swapV3) from the built calldata:
        uint256 encodedDeadline;
        bytes memory args = new bytes(cd.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = cd[i + 4];
        }
        if (best.source == zQuoter.AMM.PCS_V2 || best.source == zQuoter.AMM.SUSHI) {
            (,,,,,, encodedDeadline) =
                abi.decode(args, (address, bool, address, address, uint256, uint256, uint256));
        } else {
            (,,,,,,, encodedDeadline) = abi.decode(
                args, (address, bool, uint24, address, address, uint256, uint256, uint256)
            );
        }
        bool isPcs = best.source == zQuoter.AMM.PCS_V2 || best.source == zQuoter.AMM.PCS_V3;
        if (isPcs) {
            assertNotEq(
                encodedDeadline, type(uint256).max, "PCS winner must not inherit max deadline"
            );
        } else {
            // alt venues legitimately encode max (legacy no-expiry form of the venue bit)
            assertEq(encodedDeadline, type(uint256).max);
        }
        // and the built swap must execute on the quoted venue:
        uint256 balBefore = IERC20(USDT).balanceOf(USER);
        vm.prank(USER);
        (bool ok,) = address(router).call{value: 1 ether}(cd);
        assertTrue(ok, "clamped built swap failed");
        assertEq(IERC20(USDT).balanceOf(USER) - balBefore, best.amountOut);
    }

    /// @dev V3 pools stop at the price limit instead of reverting on exact-out
    ///      under-delivery — the router must never silently succeed with a short fill.
    function testV3_ExactOut_UnderdeliverReverts() public {
        // the 2500-tier pool holds only ~3.4 ETH, so a 10 ETH exact-out cannot fill.
        // Two protection layers can fire: the new Slippage shortfall check when the
        // partial input is affordable, or TransferFromFailed when the price walk to
        // the limit makes it unaffordable (the usual live-pool case). Success with a
        // short fill — the pre-fix behavior — must not happen:
        bytes memory cd = abi.encodeCall(
            zRouter.swapV3, (USER, true, 2500, USDT, ETH_BSC, 10 ether, 0, block.timestamp + 1000)
        );
        vm.prank(USER);
        (bool ok, bytes memory rd) = address(router).call(cd);
        assertTrue(!ok, "oversized exact-out must revert");
        bytes4 sel = rd.length >= 4 ? bytes4(rd) : bytes4(0);
        assertTrue(
            sel == zRouter.Slippage.selector || sel == bytes4(0x7939f424), // TransferFromFailed
            "unexpected revert reason"
        );
    }

    /// @dev V2 exact-out with amountOut >= reserves must revert BadSwap, not wrap/div-by-zero.
    function testV2_ExactOut_BeyondReservesReverts() public {
        vm.prank(USER);
        vm.expectRevert(zRouter.BadSwap.selector);
        router.swapV2{value: 1 ether}(
            USER, true, address(0), USDT, type(uint112).max, 0, block.timestamp + 1000
        );
    }

    /// @dev The V3 callback is bound to the in-flight swap — direct fallback calls revert.
    function testV3Callback_DirectCallReverts() public {
        bytes memory evilData =
            abi.encodePacked(false, false, WHALE, ETH_BSC, USDT, address(this), uint24(500));
        bytes memory cd = abi.encodePacked(
            bytes4(0xfa461e33), int256(1), int256(-1), evilData // uniswapV3SwapCallback shape
        );
        vm.expectRevert(zRouter.Unauthorized.selector); // no in-flight swap bound
        address(router).call(cd);
    }

    function _logQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 amount) internal {
        zQuoter.Quote[] memory qs = quoter.getQuotes(exactOut, tokenIn, tokenOut, amount);
        for (uint256 i; i < qs.length; ++i) {
            console2.log("  src:", uint8(qs[i].source), "feeBps:", qs[i].feeBps);
            console2.log("    in:", qs[i].amountIn, "out:", qs[i].amountOut);
        }
    }
}
