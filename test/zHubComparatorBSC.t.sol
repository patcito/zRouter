// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test, console2} from "@forge/Test.sol";
import {zRouter} from "../src/bsc/zRouter.sol";
import {zQuoter} from "../src/bsc/zQuoter.sol";
import {ZHubComparator} from "../src/bsc/ZHubComparator.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev BSC fork tests for ZHubComparator. The key assertion is that the emitted
///      calldata actually EXECUTES, since the two-leg route relies on zRouter's
///      swapAmount = 0 auto-consume convention and transient-balance chaining.
contract ZHubComparatorBSCTest is Test {
    zRouter router;
    zQuoter quoter;
    ZHubComparator comparator;

    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant ETH_BSC = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    address constant WHALE = 0x8894E0a0c962CB723c1976a4421c95949bE2D4E3; // binance hot wallet

    address USER = makeAddr("USER");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("bsc"), 111_979_470);
        router = new zRouter();
        quoter = new zQuoter();
        comparator = new ZHubComparator(address(quoter), address(router));
        vm.deal(USER, 100 ether);
        vm.startPrank(WHALE);
        IERC20(USDT).transfer(USER, 1_000_000 ether);
        IERC20(CAKE).transfer(USER, 100_000 ether);
        IERC20(ETH_BSC).transfer(USER, 100 ether);
        vm.stopPrank();
    }

    function _dl() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    /// Direct-routable pair: comparator must be at least as good as the quoter's
    /// own single-hop builder, and the direct calldata must execute.
    function test_DirectRoute_Executes() public {
        (uint256 quoted, bytes memory cd, bool viaHub,) =
            comparator.bestExactIn(USER, USDT, WBNB, 10_000 ether, 100, _dl());
        zQuoter.Quote memory direct = quoter.bestQuote(false, USDT, WBNB, 10_000 ether);
        console2.log("direct USDT->WBNB:", quoted, "viaHub:", viaHub);
        assertFalse(viaHub, "deep direct pair should not route via hub");
        assertGe(quoted, direct.amountOut, "regressed against direct quote");

        vm.prank(USER);
        IERC20(USDT).approve(address(router), 10_000 ether);
        uint256 before = IERC20(WBNB).balanceOf(USER);
        vm.prank(USER);
        (bool ok,) = address(router).call(cd);
        assertTrue(ok, "direct calldata reverted");
        uint256 received = IERC20(WBNB).balanceOf(USER) - before;
        assertGe(received, quoted * 99 / 100, "received materially less than quoted");
    }

    /// CAKE->BTCB has only dust direct pools (~2.5k CAKE / 0.05 BTCB on PCS V2),
    /// so a hub route must win for size. This is the feature the comparator adds.
    function test_HubRoute_Wins() public {
        (uint256 out, bytes memory cd, bool viaHub, address hub) =
            comparator.bestExactIn(USER, CAKE, BTCB, 1000 ether, 100, _dl());
        zQuoter.Quote memory direct = quoter.bestQuote(false, CAKE, BTCB, 1000 ether);
        console2.log("comparator out:", out, "direct out:", direct.amountOut);
        console2.log("hub:", hub);
        assertTrue(viaHub, "expected a hub route to beat the dust direct pool");
        assertGt(out, direct.amountOut, "hub route must beat the direct quote");
        assertGt(cd.length, 0);
    }

    /// The two-leg calldata must actually execute: leg 1 lands the intermediate
    /// in the router, leg 2 auto-consumes it (swapAmount = 0).
    function test_HubRoute_Executes() public {
        (uint256 quoted, bytes memory cd, bool viaHub,) =
            comparator.bestExactIn(USER, CAKE, BTCB, 1000 ether, 100, _dl());
        assertTrue(viaHub, "expected a hub route");

        vm.prank(USER);
        IERC20(CAKE).approve(address(router), 1000 ether);
        uint256 before = IERC20(BTCB).balanceOf(USER);
        vm.prank(USER);
        (bool ok,) = address(router).call(cd);
        assertTrue(ok, "hub calldata reverted");
        uint256 received = IERC20(BTCB).balanceOf(USER) - before;
        console2.log("quoted:", quoted, "received:", received);
        assertGt(received, 0, "received nothing");
        assertGe(received, quoted * 99 / 100, "received materially less than quoted");
    }

    /// Regression (review H1): a stray intermediate-token balance in the router
    /// must not redirect leg 2's input to the caller's wallet. With credit-based
    /// auto-consume sizing, donated dust is ignored by the route and survives in
    /// the router. NOTE: the donation must be in the token the route actually
    /// uses (returned `hub`) — donating any other token proves nothing.
    function test_HubRoute_ImmuneToDonatedDust() public {
        (uint256 quoted, bytes memory cd, bool viaHub, address hub) =
            comparator.bestExactIn(USER, CAKE, BTCB, 1000 ether, 100, _dl());
        assertTrue(viaHub, "expected a hub route");

        // attacker griefs: 1 wei of the actual hub token lands in the router
        vm.prank(WHALE);
        IERC20(hub).transfer(address(router), 1);
        // user even has a hub-token allowance (repeat zRouter user pattern):
        vm.prank(WHALE);
        IERC20(hub).transfer(USER, 1_000 ether);
        vm.startPrank(USER);
        IERC20(CAKE).approve(address(router), 1000 ether);
        IERC20(hub).approve(address(router), type(uint256).max);
        uint256 hubBefore = IERC20(hub).balanceOf(USER);
        uint256 btcbBefore = IERC20(BTCB).balanceOf(USER);
        (bool ok,) = address(router).call(cd);
        vm.stopPrank();
        assertTrue(ok, "hub calldata reverted on donated dust");
        assertEq(IERC20(hub).balanceOf(USER), hubBefore, "user hub tokens were pulled");
        assertEq(
            IERC20(hub).balanceOf(address(router)), 1, "donated dust must be left untouched"
        );
        uint256 received = IERC20(BTCB).balanceOf(USER) - btcbBefore;
        assertGe(received, quoted * 99 / 100, "received materially less than quoted");
        console2.log("dust-immune hub route via:", hub, "received:", received);
    }

    /// Structural: the emitted two-leg calldata must be multicall([leg1, leg2])
    /// with leg 1 delivering into the router and leg 2 auto-consuming (swapAmount 0).
    function test_HubCalldata_Structure() public {
        (, bytes memory cd, bool viaHub,) =
            comparator.bestExactIn(USER, CAKE, BTCB, 1000 ether, 100, _dl());
        assertTrue(viaHub, "expected a hub route");
        assertEq(bytes4(cd), zRouter.multicall.selector);
        bytes memory args = new bytes(cd.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = cd[i + 4];
        }
        bytes[] memory calls = abi.decode(args, (bytes[]));
        assertEq(calls.length, 2);
        (address to1, uint256 amt1) = _decodeLeg(calls[0]);
        (address to2, uint256 amt2) = _decodeLeg(calls[1]);
        assertEq(to1, address(router), "leg 1 must deliver into the router");
        assertEq(amt1, 1000 ether, "leg 1 uses the exact input");
        assertEq(to2, USER, "leg 2 delivers to the recipient");
        assertEq(amt2, 0, "leg 2 must auto-consume (swapAmount == 0)");
    }

    /// @dev Extract (to, swapAmount) from an encoded swapV2 or swapV3 leg.
    function _decodeLeg(bytes memory cd) internal pure returns (address to, uint256 swapAmount) {
        bytes memory args = new bytes(cd.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = cd[i + 4];
        }
        if (bytes4(cd) == zRouter.swapV2.selector) {
            (to,,,, swapAmount,,) =
                abi.decode(args, (address, bool, address, address, uint256, uint256, uint256));
        } else if (bytes4(cd) == zRouter.swapV3.selector) {
            uint24 fee;
            (to,, fee,,, swapAmount,,) = abi.decode(
                args, (address, bool, uint24, address, address, uint256, uint256, uint256)
            );
            assertGt(uint256(fee), 0, "V3 leg must carry a fee tier");
        } else {
            revert("unexpected leg selector");
        }
    }

    /// Across a few pairs the comparator must never be worse than the direct quote
    /// (baseline: the quoter's buildable direct quote — same universe the comparator draws from).
    function test_NeverWorseThanDirect() public {
        address[3] memory ins = [USDT, ETH_BSC, CAKE];
        address[3] memory outs = [WBNB, BTCB, USDT];
        uint256[3] memory amts = [uint256(10_000 ether), 1 ether, 100 ether];
        for (uint256 i; i < ins.length; ++i) {
            (uint256 out,,,) = comparator.bestExactIn(USER, ins[i], outs[i], amts[i], 50, _dl());
            (, zQuoter.Quote memory direct) =
                quoter.buildBestSwap(USER, false, ins[i], outs[i], amts[i], 0, _dl());
            assertGt(direct.amountOut, 0, "test pair unexpectedly has no direct quote");
            assertGe(out, direct.amountOut, "comparator regressed against the direct route");
        }
    }

    /// A pair with no liquidity anywhere must revert NoRoute.
    function test_NoRoute() public {
        vm.expectRevert(ZHubComparator.NoRoute.selector);
        comparator.bestExactIn(
            USER, USDT, 0x000000000000000000000000000000000000dEaD, 1000 ether, 50, _dl()
        );
    }

    function test_RejectsDegenerateInputs() public {
        vm.expectRevert(bytes("native BNB unsupported"));
        comparator.bestExactIn(USER, address(0), USDT, 1 ether, 50, _dl());
        vm.expectRevert(bytes("identical tokens"));
        comparator.bestExactIn(USER, USDT, USDT, 1 ether, 50, _dl());
        vm.expectRevert(bytes("zero amount"));
        comparator.bestExactIn(USER, CAKE, USDT, 0, 50, _dl());
        vm.expectRevert(bytes("slippage out of range"));
        comparator.bestExactIn(USER, CAKE, USDT, 1 ether, 10_000, _dl());
        vm.expectRevert(bytes("deadline must be a future plain timestamp"));
        comparator.bestExactIn(USER, CAKE, USDT, 1 ether, 50, block.timestamp - 1);
        vm.expectRevert(bytes("deadline must be a future plain timestamp"));
        comparator.bestExactIn(USER, CAKE, USDT, 1 ether, 50, (1 << 255) | _dl());
    }
}
