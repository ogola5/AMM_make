// Test actor for the AMM canister
import AMM "../amm_maker_backend/main";

actor {
  public shared func runTests() : async () {
    // ============================================================================
    //  Initial State Checks
    // ============================================================================

    // Initially, the pool should be empty.
    let initialState = await AMM.getPoolState();
    assert(initialState.tokenABalance == 0);
    assert(initialState.tokenBBalance == 0);
    assert(initialState.totalShares == 0);

    // Test addLiquidity with zero amounts (should return an error).
    // Note: Our addLiquidity now returns an error for zero amounts.
    assert((await AMM.addLiquidity(0, 0)) == #err("Amounts must be greater than zero."));
    let stateAfterZeroLiquidity = await AMM.getPoolState();
    assert(stateAfterZeroLiquidity.tokenABalance == 0);
    assert(stateAfterZeroLiquidity.tokenBBalance == 0);
    assert(stateAfterZeroLiquidity.totalShares == 0);

    // ============================================================================
    //  Adding Liquidity
    // ============================================================================

    // Add initial liquidity (e.g., 200 of TokenA and 100 of TokenB).
    // When totalShares is zero, LP tokens are minted as natSqrt(200*100) = natSqrt(20000).
    // With integer arithmetic (flooring), we expect 141 LP tokens.
    assert((await AMM.addLiquidity(200, 100)) == #ok(true));
    let stateAfterInit = await AMM.getPoolState();
    assert(stateAfterInit.tokenABalance == 200);
    assert(stateAfterInit.tokenBBalance == 100);
    assert(stateAfterInit.totalShares == 141);

    // Check the caller's LP token balance.
    // (Assuming the test actor is the one that called addLiquidity.)
    let userBalance = await AMM.getUserLPBalance(Principal.fromActor(this));
    assert(userBalance == 141);

    // ============================================================================
    //  Simulating and Executing Swaps
    // ============================================================================

    // Test simulateSwap with an input amount of 0 (should return an error).
    assert((await AMM.simulateSwap(#TokenA, 0)) == #err("Input amount must be greater than zero."));

    // Test simulateSwap with a valid input.
    // Calculation details:
    //   amountInAfterFee = floor(10 * (10000 - 30) / 10000) = floor(10 * 9970 / 10000) = 9.
    //   New TokenA balance would be 200 + 9 = 209.
    //   k = 200 * 100 = 20000, so new TokenB balance = floor(20000 / 209) = 95.
    //   Thus, expected amountOut = 100 - 95 = 5.
    assert((await AMM.simulateSwap(#TokenA, 10)) == #ok(5));

    // Test swap with an input amount of 0 (should return an error).
    assert((await AMM.swap(#TokenA, 0)) == #err("Input amount must be greater than zero."));

    // Execute a valid swap.
    // Using the same calculation as above, swapping 10 of TokenA should yield 5 of TokenB.
    assert((await AMM.swap(#TokenA, 10)) == #ok(5));

    // After the swap:
    //   - TokenA balance increases from 200 to 210 (200 + 10).
    //   - TokenB balance decreases from 100 to 95 (100 - 5).
    //   - totalShares remains 141.
    let stateAfterSwap = await AMM.getPoolState();
    assert(stateAfterSwap.tokenABalance == 210);
    assert(stateAfterSwap.tokenBBalance == 95);
    assert(stateAfterSwap.totalShares == 141);

    // ============================================================================
    //  Removing Liquidity
    // ============================================================================

    // Test removeLiquidity with 0 LP tokens (should return an error).
    assert((await AMM.removeLiquidity(0)) == #err("Invalid LP token amount: cannot remove zero."));

    // Test removeLiquidity with more LP tokens than the user has.
    // The user holds 141 LP tokens; attempting to remove 200 should fail.
    assert((await AMM.removeLiquidity(200)) == #err("Insufficient LP tokens: requested amount exceeds balance."));

    // Remove 50 LP tokens.
    // Expected calculation:
    //   tokenAWithdraw = floor(50 * 210 / 141) = floor(10500 / 141) = 74.
    //   tokenBWithdraw = floor(50 * 95 / 141) = floor(4750 / 141) = 33.
    switch (await AMM.removeLiquidity(50)) {
      case (#ok result) {
        assert(result.amountA == 74);
        assert(result.amountB == 33);
      };
      case (#err _) {
        assert(false);
      };
    };

    // After removal:
    //   - TokenA: 210 - 74 = 136.
    //   - TokenB: 95 - 33 = 62.
    //   - totalShares: 141 - 50 = 91.
    let stateAfterRemoval = await AMM.getPoolState();
    assert(stateAfterRemoval.tokenABalance == 136);
    assert(stateAfterRemoval.tokenBBalance == 62);
    assert(stateAfterRemoval.totalShares == 91);

    // ============================================================================
    //  Additional Function Tests
    // ============================================================================

    // Test getPoolPrice.
    // Expected price = TokenB balance / TokenA balance = 62 / 136 ≈ 0.4559.
    let poolPrice = await AMM.getPoolPrice();
    // Allow a small margin for floating-point arithmetic.
    assert(poolPrice > 0.45 and poolPrice < 0.46);

    // Test updateFee: Since the caller is not the admin (the admin is defined as Principal.fromActor(AMM)),
    // this call should return an unauthorized error.
    assert((await AMM.updateFee(20)) == #err("Unauthorized: Only the admin can update the fee."));
  };
};
