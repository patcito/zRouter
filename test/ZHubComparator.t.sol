// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "@forge/Test.sol";
import {ZHubComparator, IZQuoter, IZRouter} from "../src/ZHubComparator.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// Fork tests against Ethereum. Run with:
///   forge test --match-path ZHubComparator.t.sol --fork-url $ETH_RPC_URL
///
/// The point of these is not that the numbers are pretty, it is that the
/// calldata the comparator emits actually EXECUTES, since the two-leg route
/// relies on zRouter's swapAmount = 0 auto-consume convention.
contract ZHubComparatorTest is Test {
    ZHubComparator internal comparator;

    IZQuoter internal constant QUOTER = IZQuoter(0x0180Fe9Ae92Cd04dA670F974DE9d928EA69CfA66);
    address internal constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    address internal constant MKR = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant FTUSD = 0xF7D85EC4E7710f71992752eac2111312e73E9C9C;

    address internal recipient = address(0xBEEF);

    function setUp() public {
        comparator = new ZHubComparator();
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    /// The reason this contract exists: on MKR->USDC the deployed builder
    /// short-circuits to a poor direct route, and the comparator must beat it by
    /// finding the hub route the same quoter can already price.
    function test_BeatsDeployedBuilderOnMKR() public {
        uint256 amountIn = 1e18;

        (uint256 out, bytes memory cd, bool viaHub, address hub) =
            comparator.bestExactIn(recipient, MKR, USDC, amountIn, 50, _deadline());

        (IZQuoter.Quote memory direct,,,) =
            QUOTER.buildBestSwap(recipient, false, MKR, USDC, amountIn, 50, _deadline());

        emit log_named_uint("comparator out", out);
        emit log_named_uint("deployed direct out", direct.amountOut);
        emit log_named_address("hub", hub);

        assertTrue(viaHub, "expected a hub route to win for MKR->USDC");
        assertGt(out, direct.amountOut, "comparator must beat the short-circuited direct route");
        assertGt(cd.length, 0, "expected executable calldata");
    }

    /// The calldata must actually work. This is the assertion that validates the
    /// swapAmount = 0 auto-consume assumption end to end.
    function test_HubCalldataExecutes() public {
        uint256 amountIn = 1e18;
        (uint256 quoted, bytes memory cd, bool viaHub,) =
            comparator.bestExactIn(recipient, MKR, USDC, amountIn, 100, _deadline());
        assertTrue(viaHub, "expected a hub route");

        deal(MKR, address(this), amountIn);
        IERC20(MKR).approve(ZROUTER, amountIn);

        uint256 before = IERC20(USDC).balanceOf(recipient);
        (bool ok,) = ZROUTER.call(cd);
        assertTrue(ok, "zRouter execution reverted");
        uint256 received = IERC20(USDC).balanceOf(recipient) - before;

        emit log_named_uint("quoted", quoted);
        emit log_named_uint("received", received);

        assertGt(received, 0, "recipient received nothing");
        // Within 1% of quote: the executed route is the one we priced.
        assertGe(received, quoted * 99 / 100, "received materially less than quoted");
    }

    /// A direct-routable pair must not regress: the comparator has to be at
    /// least as good as the deployed builder everywhere.
    function test_NeverWorseThanDeployedDirect() public {
        address[3] memory ins = [USDC, FTUSD, WETH];
        address[3] memory outs = [USDT, USDC, USDC];
        uint256[3] memory amts = [uint256(1_000_000e6), 1_000e6, 10e18];

        for (uint256 i; i < ins.length; ++i) {
            (uint256 out,,,) = comparator.bestExactIn(recipient, ins[i], outs[i], amts[i], 50, _deadline());

            uint256 directOut;
            try QUOTER.buildBestSwap(recipient, false, ins[i], outs[i], amts[i], 50, _deadline()) returns (
                IZQuoter.Quote memory q, bytes memory, uint256, uint256
            ) {
                directOut = q.amountOut;
            } catch {}

            emit log_named_uint("comparator", out);
            emit log_named_uint("deployed   ", directOut);
            assertGe(out, directOut, "comparator regressed against the direct route");
        }
    }

    /// A direct-routable pair's calldata must execute too, so the direct
    /// pass-through path is covered as well as the hub path.
    function test_DirectCalldataExecutes() public {
        uint256 amountIn = 10_000e6;
        (uint256 quoted, bytes memory cd,,) =
            comparator.bestExactIn(recipient, USDC, WETH, amountIn, 100, _deadline());

        deal(USDC, address(this), amountIn);
        IERC20(USDC).approve(ZROUTER, amountIn);

        uint256 before = IERC20(WETH).balanceOf(recipient);
        (bool ok,) = ZROUTER.call(cd);
        assertTrue(ok, "zRouter execution reverted");
        uint256 received = IERC20(WETH).balanceOf(recipient) - before;

        assertGt(received, 0, "recipient received nothing");
        assertGe(received, quoted * 99 / 100, "received materially less than quoted");
    }

    function test_RejectsNativeAndDegenerateInputs() public {
        vm.expectRevert(bytes("native ETH unsupported"));
        comparator.bestExactIn(recipient, address(0), USDC, 1e18, 50, _deadline());

        vm.expectRevert(bytes("identical tokens"));
        comparator.bestExactIn(recipient, USDC, USDC, 1e18, 50, _deadline());

        vm.expectRevert(bytes("zero amount"));
        comparator.bestExactIn(recipient, MKR, USDC, 0, 50, _deadline());
    }

    /// type(uint256).max is zRouter's SushiSwap sentinel in swapV2, not "no
    /// expiry". Passing it through would execute a Uniswap V2 route on Sushi.
    function test_MaxDeadlineDoesNotRerouteToSushi() public {
        uint256 amountIn = 10_000e6;

        (uint256 quoted, bytes memory cd,,) =
            comparator.bestExactIn(recipient, USDC, WETH, amountIn, 100, type(uint256).max);
        assertGt(cd.length, 0, "expected calldata");

        // The clamp must not break execution, and the fill must still match the
        // quote — i.e. we ran on the venue we priced.
        deal(USDC, address(this), amountIn);
        IERC20(USDC).approve(ZROUTER, amountIn);
        uint256 before = IERC20(WETH).balanceOf(recipient);
        (bool ok,) = ZROUTER.call(cd);
        assertTrue(ok, "execution reverted with a max deadline");
        uint256 received = IERC20(WETH).balanceOf(recipient) - before;
        assertGe(received, quoted * 99 / 100, "max-deadline route did not match its quote");
    }

    /// The attack that decided leg-2 sizing: anyone can transfer dust of the hub
    /// token to zRouter. With auto-consume (swapAmount = 0) the router would try
    /// to spend delivery + dust while only delivery is credited, fall through to
    /// safeTransferFrom against the CALLER, and either revert or fund the swap
    /// from the caller's wallet while leg 1's proceeds sat sweepable by anyone.
    /// Sizing leg 2 to leg 1's enforced floor makes the credit always sufficient.
    function test_HubRouteSurvivesDustDonation() public {
        uint256 amountIn = 1e18;
        (uint256 quoted, bytes memory cd, bool viaHub, address hub) =
            comparator.bestExactIn(recipient, MKR, USDC, amountIn, 100, _deadline());
        assertTrue(viaHub, "expected a hub route");

        // A griefer donates dust of the intermediate to the router.
        deal(hub, address(this), 1);
        IERC20(hub).transfer(ZROUTER, 1);

        deal(MKR, address(this), amountIn);
        IERC20(MKR).approve(ZROUTER, amountIn);
        // Deliberately grant NO allowance for the hub token: if the route ever
        // falls back to pulling the intermediate from us, this reverts.
        uint256 before = IERC20(USDC).balanceOf(recipient);
        (bool ok,) = ZROUTER.call(cd);
        assertTrue(ok, "dust donation bricked the hub route");
        uint256 received = IERC20(USDC).balanceOf(recipient) - before;
        assertGe(received, quoted * 95 / 100, "dust donation degraded the fill");
    }

    /// Leg 1's surplus over its floor must reach the recipient rather than
    /// stranding in the router, where the public sweep makes it anyone's.
    function test_SurplusIsSweptToRecipient() public {
        uint256 amountIn = 1e18;
        (, bytes memory cd, bool viaHub, address hub) =
            comparator.bestExactIn(recipient, MKR, USDC, amountIn, 100, _deadline());
        assertTrue(viaHub, "expected a hub route");

        uint256 routerBefore = IERC20(hub).balanceOf(ZROUTER);
        deal(MKR, address(this), amountIn);
        IERC20(MKR).approve(ZROUTER, amountIn);
        (bool ok,) = ZROUTER.call(cd);
        assertTrue(ok, "execution reverted");

        assertLe(
            IERC20(hub).balanceOf(ZROUTER), routerBefore, "intermediate surplus was left stranded in the router"
        );
    }

    /// The deployed quoter misprices Curve underlying (meta) pools: 1,000 USDC to
    /// USDT has been observed quoting ~2,196 USDT, a 2.2x return on a stablecoin
    /// pair, whose calldata then reverts. Any route touching one must be
    /// discarded rather than returned as a winner.
    function test_RejectsMispricedUnderlyingCurveRoute() public {
        uint256 amountIn = 1_000e6;

        (uint256 out, bytes memory cd,,) =
            comparator.bestExactIn(recipient, USDC, USDT, amountIn, 100, _deadline());

        // Whatever survives must be sane for a stablecoin pair: never a multiple
        // of the input. The mispriced quote would show ~2.19e9 for a 1e9 input.
        emit log_named_uint("USDC->USDT out", out);
        assertLt(out, amountIn * 12 / 10, "returned an implausible stablecoin quote");

        // And it must actually execute.
        deal(USDC, address(this), amountIn);
        IERC20(USDC).approve(ZROUTER, amountIn);
        uint256 before = IERC20(USDT).balanceOf(recipient);
        (bool ok,) = ZROUTER.call(cd);
        assertTrue(ok, "returned route reverted");
        assertGt(IERC20(USDT).balanceOf(recipient) - before, 0, "recipient got nothing");
    }
}
