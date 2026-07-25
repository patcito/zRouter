// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @dev pancakeV2 / sushi / pancakeV3 / uniV3 / uniV4 / curve / zaps
///      multi-amm multi-call router (BNB Smart Chain)
///      optimized with simple abi.
///      `deadline == type(uint256).max` selects SushiSwap (swapV2)
///      or Uniswap V3 (swapV3) instead of PancakeSwap.
contract zRouter {
    error BadSwap();
    error Expired();
    error Slippage();
    error InvalidId();
    error Unauthorized();
    error InvalidMsgVal();
    error ETHTransferFailed();
    error SnwapSlippage(address token, uint256 received, uint256 minimum);

    SafeExecutor public immutable safeExecutor;

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, Expired());
        _;
    }

    event OwnershipTransferred(address indexed from, address indexed to);

    constructor() payable {
        safeExecutor = new SafeExecutor();
        emit OwnershipTransferred(address(0), _owner = tx.origin);
    }

    function swapV2(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);

        if (ethIn) tokenIn = WBNB;
        if (ethOut) tokenOut = WBNB;

        bool sushiSwap;
        unchecked {
            if (deadline == type(uint256).max) {
                (sushiSwap, deadline) = (true, block.timestamp + 30 minutes);
            }
        }
        // PancakeSwap V2 charges 0.25% (9975/10000); SushiSwap charges 0.3% (997/1000):
        (uint256 feeNum, uint256 feeDen) = sushiSwap ? (uint256(997), 1000) : (uint256(9975), 10000);

        (address pool, bool zeroForOne) = _v2PoolFor(tokenIn, tokenOut, sushiSwap);
        (uint112 r0, uint112 r1,) = IV2Pool(pool).getReserves();
        (uint256 resIn, uint256 resOut) = zeroForOne ? (r0, r1) : (r1, r0);

        unchecked {
            if (exactOut) {
                amountOut = swapAmount; // target
                if (amountOut >= resOut) revert BadSwap(); // pair cannot deliver it
                uint256 n = resIn * amountOut * feeDen;
                uint256 d = (resOut - amountOut) * feeNum;
                amountIn = (n + d - 1) / d; // ceil-div
                require(amountLimit == 0 || amountIn <= amountLimit, Slippage());
            } else {
                if (swapAmount == 0) {
                    amountIn = ethIn ? msg.value : balanceOf(tokenIn);
                    if (amountIn == 0) revert BadSwap();
                } else {
                    amountIn = swapAmount;
                }
                amountOut = (amountIn * feeNum * resOut) / (resIn * feeDen + amountIn * feeNum);
                require(amountLimit == 0 || amountOut >= amountLimit, Slippage());
            }
            if (!_useTransientBalance(pool, tokenIn, 0, amountIn)) {
                if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                    safeTransfer(tokenIn, pool, amountIn);
                } else if (ethIn) {
                    wrapETH(pool, amountIn);
                    if (to != address(this)) {
                        if (msg.value > amountIn) {
                            _safeTransferETH(msg.sender, msg.value - amountIn);
                        }
                    }
                } else {
                    safeTransferFrom(tokenIn, msg.sender, pool, amountIn);
                }
            }
        }

        if (zeroForOne) {
            IV2Pool(pool).swap(0, amountOut, ethOut ? address(this) : to, "");
        } else {
            IV2Pool(pool).swap(amountOut, 0, ethOut ? address(this) : to, "");
        }

        if (ethOut) {
            unwrapETH(amountOut);
            _safeTransferETH(to, amountOut);
        } else {
            depositFor(tokenOut, 0, amountOut, to); // marks output target
        }
    }

    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        bool ethIn = tokenIn == address(0);
        bool ethOut = tokenOut == address(0);

        if (ethIn) tokenIn = WBNB;
        if (ethOut) tokenOut = WBNB;

        bool uniV3;
        unchecked {
            if (deadline == type(uint256).max) {
                (uniV3, deadline) = (true, block.timestamp + 30 minutes);
            }
        }

        (address pool, bool zeroForOne) = _v3PoolFor(tokenIn, tokenOut, swapFee, uniV3);
        uint160 sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE;

        unchecked {
            if (!exactOut && swapAmount == 0) {
                swapAmount = ethIn ? msg.value : balanceOf(tokenIn);
                if (swapAmount == 0) revert BadSwap();
            }
            // Bind the callback to this in-flight swap (pool + payer) so a directly-
            // called pool cannot trick the router into spending a third party's allowance:
            assembly ("memory-safe") {
                tstore(0x01, pool)
                tstore(0x02, caller())
            }
            (int256 a0, int256 a1) = IV3Pool(pool)
                .swap(
                    ethOut ? address(this) : to,
                    zeroForOne,
                    exactOut ? -(int256(swapAmount)) : int256(swapAmount),
                    sqrtPriceLimitX96,
                    abi.encodePacked(ethIn, ethOut, msg.sender, tokenIn, tokenOut, to, swapFee)
                );
            assembly ("memory-safe") {
                tstore(0x01, 0)
                tstore(0x02, 0)
            }

            if (amountLimit != 0) {
                if (exactOut) require(uint256(zeroForOne ? a0 : a1) <= amountLimit, Slippage());
                else require(uint256(-(zeroForOne ? a1 : a0)) >= amountLimit, Slippage());
            }

            // ── return values ────────────────────────────────
            // ── translate pool deltas to user-facing amounts ─
            (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
            amountIn = dIn >= 0 ? uint256(dIn) : uint256(-dIn);
            amountOut = dOut <= 0 ? uint256(-dOut) : uint256(dOut);
            // V3 pools do not revert on partial exact-out fills (they stop at the price
            // limit) — assert full delivery so obligations cannot be silently shorted:
            if (exactOut) require(amountOut >= swapAmount, Slippage());

            // Handle ETH input refund (separate from output tracking)
            if (ethIn) {
                if ((swapAmount = address(this).balance) != 0 && to != address(this)) {
                    _safeTransferETH(msg.sender, swapAmount);
                }
            }
            // Handle output tracking for chaining (must always run when !ethOut)
            if (!ethOut) {
                depositFor(tokenOut, 0, amountOut, to);
            }
        }
    }

    /// @dev `uniswapV3SwapCallback`.
    fallback() external payable {
        assembly ("memory-safe") {
            if gt(tload(0x00), 0) { revert(0, 0) }
        }
        unchecked {
            int256 amount0Delta;
            int256 amount1Delta;
            bool ethIn;
            bool ethOut;
            address payer;
            address tokenIn;
            address tokenOut;
            address to;
            assembly ("memory-safe") {
                amount0Delta := calldataload(0x4)
                amount1Delta := calldataload(0x24)
                ethIn := byte(0, calldataload(0x84))
                ethOut := byte(0, calldataload(add(0x84, 1)))
                payer := shr(96, calldataload(add(0x84, 2)))
                tokenIn := shr(96, calldataload(add(0x84, 22)))
                tokenOut := shr(96, calldataload(add(0x84, 42)))
                to := shr(96, calldataload(add(0x84, 62)))
                // swapFee (calldata 0x84+82) is no longer needed for authentication
            }
            require(amount0Delta != 0 || amount1Delta != 0, BadSwap());
            // Authenticate against the in-flight swap bound by swapV3 (slot 0x01/0x02):
            address expectedPool;
            address expectedPayer;
            assembly ("memory-safe") {
                expectedPool := tload(0x01)
                expectedPayer := tload(0x02)
            }
            require(expectedPool != address(0) && msg.sender == expectedPool, Unauthorized());
            address pool = expectedPool;
            payer = expectedPayer; // ignore the callback-data payer entirely
            bool zeroForOne = tokenIn < tokenOut;
            uint256 amountRequired = uint256(zeroForOne ? amount0Delta : amount1Delta);

            if (_useTransientBalance(address(this), tokenIn, 0, amountRequired)) {
                safeTransfer(tokenIn, pool, amountRequired);
            } else if (ethIn) {
                wrapETH(pool, amountRequired);
            } else {
                safeTransferFrom(tokenIn, payer, pool, amountRequired);
            }
            if (ethOut) {
                uint256 amountOut = uint256(-(zeroForOne ? amount1Delta : amount0Delta));
                unwrapETH(amountOut);
                _safeTransferETH(to, amountOut);
            }
        }
    }

    function swapCurve(
        address to,
        bool exactOut,
        address[11] calldata route,
        uint256[4][5] calldata swapParams, // [i, j, swap_type, pool_type]
        address[5] calldata basePools, // for meta pools (only used by type=2 get_dx)
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        // ---- resolve last hop & output token ----
        address inputToken = route[0];
        address outputToken;
        uint256 lastIdx;
        unchecked {
            for (uint256 i; i < 5; ++i) {
                address pool = route[i * 2 + 1];
                if (pool == address(0)) break;
                outputToken = route[(i + 1) * 2];
                lastIdx = i;
            }
        }
        bool ethIn = _isETH(inputToken);

        // ---- compute working amount ----
        uint256 amount = swapAmount;
        if (exactOut) {
            // backward pass: Curve-style get_dx to find required input:
            unchecked {
                for (uint256 k = lastIdx + 1; k != 0;) {
                    uint256 i = --k;
                    address pool = route[i * 2 + 1];
                    uint256[4] memory p = swapParams[i]; // [i, j, swap_type, pool_type]
                    uint256 st = p[2];
                    uint256 pt = p[3];

                    if (st == 8) {
                        // BNB<->WBNB is 1:1
                    } else if (st == 1) {
                        if (pt == 10) {
                            int128 pi = int128(int256(p[0]));
                            int128 pj = int128(int256(p[1]));
                            amount = IStableNgPool(pool).get_dx(pi, pj, amount) + 1;
                        } else {
                            amount = ICryptoNgPool(pool).get_dx(p[0], p[1], amount) + 1;
                        }
                    } else if (st == 2) {
                        int128 pi = int128(int256(p[0]));
                        int128 pj = int128(int256(p[1]));
                        if (pi > 0 && pj > 0) {
                            amount = IStableNgPool(basePools[i]).get_dx(pi - 1, pj - 1, amount) + 1;
                        } else {
                            amount = IStableNgMetaPool(pool).get_dx_underlying(pi, pj, amount) + 1;
                        }
                    } else if (st == 4) {
                        // inverse of add_liquidity (approx):
                        amount =
                            ((pt == 10)
                                        ? IStableNgPool(pool)
                                            .calc_withdraw_one_coin(amount, int128(int256(p[0])))
                                        : ICryptoNgPool(pool).calc_withdraw_one_coin(amount, p[0]))
                                + 1;
                    } else if (st == 6) {
                        if (pt == 10) {
                            uint256[] memory a = new uint256[](8);
                            a[p[1]] = amount;
                            amount = IStableNgPool(pool).calc_token_amount(a, false) + 1;
                        } else if (pt == 20) {
                            uint256[2] memory a2;
                            a2[p[1]] = amount;
                            amount = ITwoCryptoNgPool(pool).calc_token_amount(a2, false) + 1;
                        } else if (pt == 30) {
                            uint256[3] memory a3;
                            a3[p[1]] = amount;
                            amount = ITriCryptoNgPool(pool).calc_token_amount(a3, false) + 1;
                        } else {
                            revert BadSwap();
                        }
                    } else {
                        revert BadSwap();
                    }
                }
            }
            amountIn = amount;
            if (amountLimit != 0 && amountIn > amountLimit) revert Slippage();
        } else {
            // exact-in flow:
            if (swapAmount == 0) {
                amountIn = ethIn ? msg.value : balanceOf(inputToken);
                if (amountIn == 0) revert BadSwap();
            } else {
                amountIn = swapAmount;
                if (ethIn && msg.value != amountIn) revert InvalidMsgVal();
            }
        }

        // ---- pre-fund router (Curve pools pull via transferFrom(router)) ----
        address firstToken = ethIn ? WBNB : inputToken;

        {
            uint256 need = amountIn;
            if (!_useTransientBalance(address(this), firstToken, 0, need)) {
                if (ethIn) {
                    if (msg.value < need) revert InvalidMsgVal();
                    wrap(need); // wrap exactly what we need as WBNB
                } else {
                    safeTransferFrom(firstToken, msg.sender, address(this), need);
                }
            }
        }

        // ---- execute the route (forward pass) ----
        address curIn = inputToken;
        amount = amountIn; // start with dx

        unchecked {
            for (uint256 i; i <= lastIdx; ++i) {
                address pool = route[i * 2 + 1];
                address nextToken = route[(i + 1) * 2];
                uint256[4] memory p = swapParams[i]; // [i, j, swap_type, pool_type]
                uint256 st = p[2];
                uint256 pt = p[3];

                if (st == 8) {
                    if (_isETH(curIn) && nextToken == WBNB) {
                        // if first hop, we already wrapped in pre-fund; otherwise wrap what we just got:
                        if (i != 0) {
                            if (address(this).balance < amount) revert BadSwap();
                            wrap(amount);
                        }
                        curIn = WBNB;
                    } else if (curIn == WBNB && _isETH(nextToken)) {
                        unwrapETH(amount);
                        curIn = address(0); // normalize to 0x00 internally
                    } else {
                        revert BadSwap();
                    }
                    continue;
                }

                // ---- lazy approve current input token for this pool (ERC20 only) ----
                address inToken = _isETH(curIn) ? WBNB : curIn;
                if (allowance(inToken, address(this), pool) == 0) {
                    safeApprove(inToken, pool, type(uint256).max);
                }

                // track output balance before hop
                uint256 outBalBefore =
                    _isETH(nextToken) ? address(this).balance : balanceOf(nextToken);

                // perform hop:
                if (st == 1) {
                    if (pt == 10) {
                        IStableNgPool(pool)
                            .exchange(int128(int256(p[0])), int128(int256(p[1])), amount, 0);
                    } else {
                        ICryptoNgPool(pool).exchange(p[0], p[1], amount, 0);
                    }
                } else if (st == 2) {
                    IStableNgMetaPool(pool)
                        .exchange_underlying(int128(int256(p[0])), int128(int256(p[1])), amount, 0);
                } else if (st == 4) {
                    if (pt == 10) {
                        uint256[] memory a = new uint256[](8);
                        a[p[0]] = amount;
                        IStableNgPool(pool).add_liquidity(a, 0);
                    } else if (pt == 20) {
                        uint256[2] memory a2;
                        a2[p[0]] = amount;
                        ITwoCryptoNgPool(pool).add_liquidity(a2, 0);
                    } else if (pt == 30) {
                        uint256[3] memory a3;
                        a3[p[0]] = amount;
                        ITriCryptoNgPool(pool).add_liquidity(a3, 0);
                    } else {
                        revert BadSwap();
                    }
                } else if (st == 6) {
                    if (pt == 10) {
                        IStableNgPool(pool)
                            .remove_liquidity_one_coin(amount, int128(int256(p[1])), 0);
                    } else {
                        ICryptoNgPool(pool).remove_liquidity_one_coin(amount, p[1], 0);
                    }
                } else {
                    revert BadSwap();
                }

                // compute output of hop:
                uint256 outBalAfter =
                    _isETH(nextToken) ? address(this).balance : balanceOf(nextToken);
                if (outBalAfter <= outBalBefore) revert BadSwap();
                amount = outBalAfter - outBalBefore; // next hop input
                curIn = nextToken;
            }
        }

        // ---- finalize & slippage ----
        if (!exactOut) {
            amountOut = amount;
            if (amountLimit != 0 && amountOut < amountLimit) revert Slippage();
        } else {
            // actual produced amount is `amount`; must be >= desired swapAmount:
            if (amount < swapAmount) revert Slippage();
            amountOut = swapAmount; // user-facing target
        }

        // ---- deliver final output to `to` and refund surplus output (exactOut) ----
        if (!exactOut) {
            // deliver full amount for exact-in:
            if (_isETH(outputToken)) {
                _safeTransferETH(to, amount);
            } else if (to == address(this)) {
                depositFor(outputToken, 0, amount, to); // chaining
            } else {
                safeTransfer(outputToken, to, amount);
            }
        } else {
            // send only swapAmount to `to`; refund surplus to msg.sender:
            uint256 surplus = amount - swapAmount;
            if (_isETH(outputToken)) {
                // pay receiver
                _safeTransferETH(to, swapAmount);
                // refund any extra output
                if (surplus != 0) _safeTransferETH(msg.sender, surplus);
            } else {
                if (to == address(this)) {
                    // chaining: only mark the requested target amount
                    depositFor(outputToken, 0, swapAmount, to);
                } else {
                    safeTransfer(outputToken, to, swapAmount);
                }
                if (surplus != 0) safeTransfer(outputToken, msg.sender, surplus);
            }
        }

        // ---- leftover input refund (exactOut only, not chaining) ----
        if (exactOut && to != address(this)) {
            if (ethIn) {
                // refund any ETH dust first:
                uint256 e = address(this).balance;
                if (e != 0) _safeTransferETH(msg.sender, e);

                // refund any *WBNB* dust created by positive slippage:
                uint256 w = balanceOf(WBNB);
                if (w != 0) {
                    unwrapETH(w);
                    _safeTransferETH(msg.sender, w);
                }
            } else {
                // non-ETH inputs already use `firstToken`:
                uint256 refund = balanceOf(firstToken);
                if (refund != 0) safeTransfer(firstToken, msg.sender, refund);
            }
        }
    }

    function _isETH(address a) internal pure returns (bool r) {
        assembly { r := or(iszero(a), eq(a, CURVE_ETH)) }
    }

    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) public payable checkDeadline(deadline) returns (uint256 amountIn, uint256 amountOut) {
        if (!exactOut && swapAmount == 0) {
            swapAmount = tokenIn == address(0) ? msg.value : balanceOf(tokenIn);
            if (swapAmount == 0) revert BadSwap();
        }
        (amountIn, amountOut) = abi.decode(
            IV4PoolManager(V4_POOL_MANAGER)
                .unlock(
                    abi.encode(
                        msg.sender,
                        to,
                        exactOut,
                        swapFee,
                        tickSpace,
                        tokenIn,
                        tokenOut,
                        swapAmount,
                        amountLimit
                    )
                ),
            (uint256, uint256)
        );
        depositFor(tokenOut, 0, amountOut, to); // marks output target
    }

    /// @dev Handle V4 PoolManager swap callback - hookless default.
    function unlockCallback(bytes calldata callbackData)
        public
        payable
        returns (bytes memory result)
    {
        require(msg.sender == V4_POOL_MANAGER, Unauthorized());

        assembly ("memory-safe") {
            if gt(tload(0x00), 0) { revert(0, 0) }
        }

        (
            address payer,
            address to,
            bool exactOut,
            uint24 swapFee,
            int24 tickSpace,
            address tokenIn,
            address tokenOut,
            uint256 swapAmount,
            uint256 amountLimit
        ) = abi.decode(
            callbackData,
            (address, address, bool, uint24, int24, address, address, uint256, uint256)
        );

        bool zeroForOne = tokenIn < tokenOut;
        bool ethIn = tokenIn == address(0);

        V4PoolKey memory key = V4PoolKey(
            zeroForOne ? tokenIn : tokenOut,
            zeroForOne ? tokenOut : tokenIn,
            swapFee,
            tickSpace,
            address(0)
        );

        unchecked {
            int256 delta = _swap(swapAmount, key, zeroForOne, exactOut);
            uint256 takeAmount = zeroForOne
                ? (!exactOut
                        ? uint256(uint128(delta.amount1()))
                        : uint256(uint128(-delta.amount0())))
                : (!exactOut
                        ? uint256(uint128(delta.amount0()))
                        : uint256(uint128(-delta.amount1())));

            IV4PoolManager(msg.sender).sync(tokenIn);
            uint256 amountIn = !exactOut ? swapAmount : takeAmount;

            if (_useTransientBalance(address(this), tokenIn, 0, amountIn)) {
                if (tokenIn != address(0)) {
                    safeTransfer(
                        tokenIn,
                        msg.sender, // V4_POOL_MANAGER
                        amountIn
                    );
                }
            } else if (!ethIn) {
                safeTransferFrom(
                    tokenIn,
                    payer,
                    msg.sender, // V4_POOL_MANAGER
                    amountIn
                );
            }

            uint256 amountOut = !exactOut ? takeAmount : swapAmount;
            if (amountLimit != 0 && (exactOut ? takeAmount > amountLimit : amountOut < amountLimit))
            {
                revert Slippage();
            }

            IV4PoolManager(msg.sender)
            .settle{value: ethIn ? (exactOut ? takeAmount : swapAmount) : 0}();
            IV4PoolManager(msg.sender).take(tokenOut, to, amountOut);

            result = abi.encode(amountIn, amountOut);

            if (ethIn) {
                uint256 ethRefund = address(this).balance;
                if (ethRefund != 0 && to != address(this)) {
                    _safeTransferETH(payer, ethRefund);
                }
            }
        }
    }

    function _swap(uint256 swapAmount, V4PoolKey memory key, bool zeroForOne, bool exactOut)
        internal
        returns (int256 delta)
    {
        unchecked {
            delta = IV4PoolManager(msg.sender)
                .swap(
                    key,
                    V4SwapParams(
                        zeroForOne,
                        exactOut ? int256(swapAmount) : -int256(swapAmount),
                        zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE
                    ),
                    ""
                );
        }
    }

    function ensureAllowance(address token, bool is6909, address to) public payable onlyOwner {
        if (is6909) IERC6909(token).setOperator(to, true);
        else safeApprove(token, to, type(uint256).max);
    }

    // ** PERMIT HELPERS

    function permit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        payable
    {
        IERC2612(token).permit(msg.sender, address(this), value, deadline, v, r, s);
    }

    function permit2TransferFrom(
        address token,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) public payable {
        IPermit2(PERMIT2)
            .permitTransferFrom(
                IPermit2.PermitTransferFrom({
                    permitted: IPermit2.TokenPermissions({token: token, amount: amount}),
                    nonce: nonce,
                    deadline: deadline
                }),
                IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: amount}),
                msg.sender,
                signature
            );
        depositFor(token, 0, amount, address(this));
    }

    function permit2BatchTransferFrom(
        IPermit2.TokenPermissions[] calldata permitted,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) public payable {
        uint256 len = permitted.length;
        IPermit2.SignatureTransferDetails[] memory details =
            new IPermit2.SignatureTransferDetails[](len);

        for (uint256 i; i != len; ++i) {
            details[i] = IPermit2.SignatureTransferDetails({
                to: address(this), requestedAmount: permitted[i].amount
            });
        }

        IPermit2(PERMIT2)
            .permitBatchTransferFrom(
                IPermit2.PermitBatchTransferFrom({
                    permitted: permitted, nonce: nonce, deadline: deadline
                }),
                details,
                msg.sender,
                signature
            );

        for (uint256 i; i != len; ++i) {
            depositFor(permitted[i].token, 0, permitted[i].amount, address(this));
        }
    }

    // ** MULTISWAP HELPER

    function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i != data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
    }

    // ** TRANSIENT STORAGE

    function deposit(address token, uint256 id, uint256 amount) public payable {
        if (msg.value != 0) {
            require(id == 0, InvalidId());
            if (token == WBNB) {
                require(msg.value == amount, InvalidMsgVal());
                _safeTransferETH(WBNB, amount); // wrap to WBNB
            } else {
                require(msg.value == (token == address(0) ? amount : 0), InvalidMsgVal());
            }
        }
        if (token != address(0) && msg.value == 0) {
            if (id == 0) safeTransferFrom(token, msg.sender, address(this), amount);
            else IERC6909(token).transferFrom(msg.sender, address(this), id, amount);
        }
        depositFor(token, id, amount, address(this)); // transient storage tracker
    }

    function _useTransientBalance(address user, address token, uint256 id, uint256 amount)
        internal
        returns (bool credited)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(0x00, user)
            mstore(0x20, token)
            mstore(0x40, id)
            let slot := keccak256(0x00, 0x60)
            let bal := tload(slot)
            if iszero(lt(bal, amount)) {
                tstore(slot, sub(bal, amount))
                credited := 1
            }
            mstore(0x40, m)
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        if (to == address(this)) {
            depositFor(address(0), 0, amount, to);
            return;
        }
        assembly ("memory-safe") {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb)
                revert(0x1c, 0x04)
            }
        }
    }

    // ** RECEIVER & SWEEPER

    receive() external payable {}

    function sweep(address token, uint256 id, uint256 amount, address to) public payable {
        if (token == address(0)) {
            _safeTransferETH(to, amount == 0 ? address(this).balance : amount);
        } else if (id == 0) {
            safeTransfer(token, to, amount == 0 ? balanceOf(token) : amount);
        } else {
            IERC6909(token)
                .transfer(
                    to, id, amount == 0 ? IERC6909(token).balanceOf(address(this), id) : amount
                );
        }
    }

    // ** WBNB HELPERS

    function wrap(uint256 amount) public payable {
        amount = amount == 0 ? address(this).balance : amount;
        _safeTransferETH(WBNB, amount);
        depositFor(WBNB, 0, amount, address(this));
    }

    function unwrap(uint256 amount) public payable {
        unwrapETH(amount == 0 ? balanceOf(WBNB) : amount);
    }

    // ** POOL HELPERS

    function _v2PoolFor(address tokenA, address tokenB, bool sushiSwap)
        internal
        pure
        returns (address v2pool, bool zeroForOne)
    {
        unchecked {
            (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
            zeroForOne = zF1;
            v2pool = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                sushiSwap ? SUSHI_FACTORY : V2_FACTORY,
                                keccak256(abi.encodePacked(token0, token1)),
                                sushiSwap ? SUSHI_POOL_INIT_CODE_HASH : V2_POOL_INIT_CODE_HASH
                            )
                        )
                    )
                )
            );
        }
    }

    function _v3PoolFor(address tokenA, address tokenB, uint24 fee, bool uniV3)
        internal
        pure
        returns (address v3pool, bool zeroForOne)
    {
        (address token0, address token1, bool zF1) = _sortTokens(tokenA, tokenB);
        zeroForOne = zF1;
        v3pool = _computeV3pool(token0, token1, fee, uniV3);
    }

    function _computeV3pool(address token0, address token1, uint24 fee, bool uniV3)
        internal
        pure
        returns (address v3pool)
    {
        bytes32 salt = _hash(token0, token1, fee);
        assembly ("memory-safe") {
            mstore8(0x00, 0xff)
            if uniV3 {
                mstore(0x35, UNI_V3_POOL_INIT_CODE_HASH)
                mstore(0x01, shl(96, UNI_V3_FACTORY))
            }
            // PancakeSwap V3 pools are CREATE2'd by its poolDeployer:
            if iszero(uniV3) {
                mstore(0x35, V3_POOL_INIT_CODE_HASH)
                mstore(0x01, shl(96, V3_POOL_DEPLOYER))
            }
            mstore(0x15, salt)
            v3pool := keccak256(0x00, 0x55)
            mstore(0x35, 0)
        }
    }

    function _hash(address value0, address value1, uint24 value2)
        internal
        pure
        returns (bytes32 result)
    {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, value0)
            mstore(add(m, 0x20), value1)
            mstore(add(m, 0x40), value2)
            result := keccak256(m, 0x60)
        }
    }

    function _sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1, bool zeroForOne)
    {
        (token0, token1) = (zeroForOne = tokenA < tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // EXECUTE EXTENSIONS

    address _owner;

    modifier onlyOwner() {
        require(msg.sender == _owner, Unauthorized());
        _;
    }

    mapping(address target => bool) _isTrustedForCall;

    function trust(address target, bool ok) public payable onlyOwner {
        _isTrustedForCall[target] = ok;
    }

    function transferOwnership(address owner) public payable onlyOwner {
        emit OwnershipTransferred(msg.sender, _owner = owner);
    }

    function execute(address target, uint256 value, bytes calldata data)
        public
        payable
        returns (bytes memory result)
    {
        require(_isTrustedForCall[target], Unauthorized());
        assembly ("memory-safe") {
            tstore(0x00, 1) // lock callback (V3/V4)
            result := mload(0x40)
            calldatacopy(result, data.offset, data.length)
            if iszero(call(gas(), target, value, result, data.length, codesize(), 0x00)) {
                returndatacopy(result, 0x00, returndatasize())
                revert(result, returndatasize())
            }
            mstore(result, returndatasize())
            let o := add(result, 0x20)
            returndatacopy(o, 0x00, returndatasize())
            mstore(0x40, add(o, returndatasize()))
            tstore(0x00, 0) // unlock callback
        }
    }

    // SNWAP - GENERIC EXECUTOR ****

    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) public payable returns (uint256 amountOut) {
        uint256 initialBalance = tokenOut == address(0)
            ? recipient.balance
            : balanceOfAccount(tokenOut, recipient);

        if (tokenIn != address(0)) {
            if (amountIn != 0) {
                safeTransferFrom(tokenIn, msg.sender, executor, amountIn);
            } else {
                unchecked {
                    uint256 bal = balanceOf(tokenIn);
                    if (bal > 1) safeTransfer(tokenIn, executor, bal - 1);
                }
            }
        }

        safeExecutor.execute{value: msg.value}(executor, executorData);

        uint256 finalBalance =
            tokenOut == address(0) ? recipient.balance : balanceOfAccount(tokenOut, recipient);
        amountOut = finalBalance - initialBalance;
        if (amountOut < amountOutMin) revert SnwapSlippage(tokenOut, amountOut, amountOutMin);
        if (recipient == address(this)) depositFor(tokenOut, 0, amountOut, address(this));
    }

    function snwapMulti(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address[] calldata tokensOut,
        uint256[] calldata amountsOutMin,
        address executor,
        bytes calldata executorData
    ) public payable returns (uint256[] memory amountsOut) {
        uint256 len = tokensOut.length;
        uint256[] memory initBals = new uint256[](len);
        for (uint256 i; i != len; ++i) {
            initBals[i] = tokensOut[i] == address(0)
                ? recipient.balance
                : balanceOfAccount(tokensOut[i], recipient);
        }

        if (tokenIn != address(0)) {
            if (amountIn != 0) {
                safeTransferFrom(tokenIn, msg.sender, executor, amountIn);
            } else {
                unchecked {
                    uint256 bal = balanceOf(tokenIn);
                    if (bal > 1) safeTransfer(tokenIn, executor, bal - 1);
                }
            }
        }

        safeExecutor.execute{value: msg.value}(executor, executorData);

        amountsOut = new uint256[](len);
        for (uint256 i; i != len; ++i) {
            uint256 finalBal = tokensOut[i] == address(0)
                ? recipient.balance
                : balanceOfAccount(tokensOut[i], recipient);
            amountsOut[i] = finalBal - initBals[i];
            if (amountsOut[i] < amountsOutMin[i]) {
                revert SnwapSlippage(tokensOut[i], amountsOut[i], amountsOutMin[i]);
            }
            if (recipient == address(this)) {
                depositFor(tokensOut[i], 0, amountsOut[i], address(this));
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        public
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }
}

// Curve helpers:

address constant CURVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

interface IStableNgPool {
    function get_dx(int128 i, int128 j, uint256 out_amount) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
    // BSC stable-ng exposes dynamic-array signatures (fixed uint256[8] reverts onchain):
    function calc_token_amount(uint256[] calldata _amounts, bool _is_deposit)
        external
        view
        returns (uint256);
    function add_liquidity(uint256[] calldata _amounts, uint256 _min_mint_amount)
        external
        returns (uint256);
    function calc_withdraw_one_coin(uint256 token_amount, int128 i) external view returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, int128 i, uint256 min_amount) external;
}

interface IStableNgMetaPool {
    function get_dx_underlying(int128 i, int128 j, uint256 amount) external view returns (uint256);
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

interface ICryptoNgPool {
    function get_dx(uint256 i, uint256 j, uint256 out_amount) external view returns (uint256);
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external;
    function calc_withdraw_one_coin(uint256 token_amount, uint256 i) external view returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount) external;
}

interface ITwoCryptoNgPool {
    function calc_token_amount(uint256[2] calldata amounts, bool is_deposit)
        external
        view
        returns (uint256);
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
}

interface ITriCryptoNgPool {
    function calc_token_amount(uint256[3] calldata amounts, bool is_deposit)
        external
        view
        returns (uint256);
    function add_liquidity(uint256[3] calldata amounts, uint256 min_mint_amount)
        external
        returns (uint256);
}

// Uniswap helpers:

// PancakeSwap V2 (0.25% fee):
address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
bytes32 constant V2_POOL_INIT_CODE_HASH =
    0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5;

// SushiSwap on BSC (0.3% fee) — selected via `deadline == type(uint256).max`:
address constant SUSHI_FACTORY = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
bytes32 constant SUSHI_POOL_INIT_CODE_HASH =
    0xe18a34eb0e04b04f7a0ac29a6e80748dca96319b42c54d679cb821dca90c6303;

interface IV2Pool {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32);
}

// PancakeSwap V3 — pools are CREATE2-deployed by its poolDeployer
// (factory 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865 is only needed offchain):
address constant V3_POOL_DEPLOYER = 0x41ff9AA7e16B8B1a8a8dc4f0eFacd93D02d071c9;
bytes32 constant V3_POOL_INIT_CODE_HASH =
    0x6ce8eb472fa82df5469c6ab6d485f17c3ad13c8cd7af59b3d4a8026c5ce0f7e2;

// Uniswap V3 on BSC — selected via `deadline == type(uint256).max`:
address constant UNI_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
bytes32 constant UNI_V3_POOL_INIT_CODE_HASH =
    0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
uint160 constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
uint160 constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

interface IV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

address constant V4_POOL_MANAGER = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF; // BSC

struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct V4SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

using BalanceDeltaLibrary for int256;

library BalanceDeltaLibrary {
    function amount0(int256 balanceDelta) internal pure returns (int128 _amount0) {
        assembly ("memory-safe") {
            _amount0 := sar(128, balanceDelta)
        }
    }

    function amount1(int256 balanceDelta) internal pure returns (int128 _amount1) {
        assembly ("memory-safe") {
            _amount1 := signextend(15, balanceDelta)
        }
    }
}

// Solady safe transfer helpers:

error TransferFailed();

function safeTransfer(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x90b8ec18)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

error TransferFromFailed();

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, from))
        mstore(0x0c, 0x23b872dd000000000000000000000000)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x7939f424)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

error ApproveFailed();

function safeApprove(address token, address to, uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, to)
        mstore(0x34, amount)
        mstore(0x00, 0x095ea7b3000000000000000000000000)
        let success := call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x3e3f8f73)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x34, 0)
    }
}

function balanceOf(address token) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, address())
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(
            mload(0x20),
            and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
        )
    }
}

function balanceOfAccount(address token, address account) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, account)
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(
            mload(0x20),
            and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
        )
    }
}

// ** ERC6909

interface IERC6909 {
    function setOperator(address spender, bool approved) external returns (bool);
    function balanceOf(address owner, uint256 id) external view returns (uint256 amount);
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool);
}

// Low-level WBNB helpers - we know WBNB so we can make assumptions:

address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // Wrapped BNB

function wrapETH(address pool, uint256 amount) {
    assembly ("memory-safe") {
        pop(call(gas(), WBNB, amount, codesize(), 0x00, codesize(), 0x00))
        mstore(0x14, pool)
        mstore(0x34, amount)
        mstore(0x00, 0xa9059cbb000000000000000000000000)
        pop(call(gas(), WBNB, 0, 0x10, 0x44, codesize(), 0x00))
        mstore(0x34, 0)
    }
}

function unwrapETH(uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x00, 0x2e1a7d4d)
        mstore(0x20, amount)
        pop(call(gas(), WBNB, 0, 0x1c, 0x24, codesize(), 0x00))
    }
}

// ** TRANSIENT DEPOSIT

function depositFor(address token, uint256 id, uint256 amount, address _for) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x00, _for)
        mstore(0x20, token)
        mstore(0x40, id)
        let slot := keccak256(0x00, 0x60)
        tstore(slot, add(tload(slot), amount))
        mstore(0x40, m)
    }
}

// ** PERMIT HELPERS

address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

interface IERC2612 {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct PermitBatchTransferFrom {
        TokenPermissions[] permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    function permitBatchTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

// ** SNWAP HELPERS

// modified from 0xAC4c6e212A361c968F1725b4d055b47E63F80b75 - sushi yum

/// @dev SafeExecutor - has no token approvals, safe for arbitrary external calls
contract SafeExecutor {
    function execute(address target, bytes calldata data) public payable {
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, data.offset, data.length)
            if iszero(call(gas(), target, callvalue(), m, data.length, codesize(), 0x00)) {
                returndatacopy(m, 0x00, returndatasize())
                revert(m, returndatasize())
            }
        }
    }
}

function allowance(address token, address owner, address spender) view returns (uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x40, spender)
        mstore(0x2c, shl(96, owner))
        mstore(0x0c, 0xdd62ed3e000000000000000000000000)
        amount := mul(
            mload(0x20),
            and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x1c, 0x44, 0x20, 0x20))
        )
        mstore(0x40, m)
    }
}
