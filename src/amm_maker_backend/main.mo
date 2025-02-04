/**
 *  @title Automated Market Maker (AMM)
 *  @author  
 *  @notice This actor implements an automated market maker (AMM) for swapping between two tokens,
 *          adding and removing liquidity, and tracking events. It uses the constant product invariant
 *          (x * y = k) to price swaps and issues liquidity provider (LP) tokens to depositors.
 *
 *  @dev This code is written in Motoko and is designed for use on the Internet Computer.
 *       The design includes:
 *         - A swap fee (default 0.3%).
 *         - Use of the constant product formula.
 *         - Detailed event logging for liquidity and swap actions.
 *         - Additional query functions for checking user balances, simulating swaps, and viewing pool state.
 *
 *  @example
 *    // Deploy and use via the DFX CLI or your front-end.
 *    // Users call addLiquidity() to deposit tokens and removeLiquidity() to withdraw.
 *    // The swap() function calculates the output based on the pool invariant.
 */
import Principal "mo:base/Principal";
import Nat "mo:base/Nat";
import Float "mo:base/Float";
import Result "mo:base/Result";
import Debug "mo:base/Debug";
import Buffer "mo:base/Buffer";
import Array "mo:base/Array";
import Int "mo:base/Int";
import StableHashMap "mo:stable-hash-map";

actor AMM {

  // ============================================================================
  //  Type Aliases and Constants
  // ============================================================================

  /// Alias representing a token amount.
  type TokenAmount = Nat;
  /// Alias representing liquidity provider tokens.
  type LPToken = Nat;

  /// Fee basis points, where 30 basis points = 0.3%.
  let feeBasisPoints : Nat = 30;
  /// Denominator used for fee calculations (basis points denominator).
  let feeDenom : Nat = 10000;

  // ============================================================================
  //  Helper Functions
  // ============================================================================

  /**
   * Computes the square root of a natural number.
   *
   * @param n The natural number input.
   * @return The square root of n, as a Nat.
   *
   * @dev This helper converts `Nat` to `Int`, then to `Float` to compute the square root,
   *      and finally converts the result back to `Nat`.
   */
  func natSqrt(n: Nat) : Nat {
    let f = Float.sqrt(Float.fromInt(Int.fromNat(n)));
    let i = Int.abs(Float.toInt(f));
    return Nat.fromInt(i);
  };

  // ============================================================================
  //  State Variables
  // ============================================================================

  /// Pool balance of Token A.
  stable var tokenABalance : TokenAmount = 0;
  /// Pool balance of Token B.
  stable var tokenBBalance : TokenAmount = 0;
  /// Total supply of liquidity provider (LP) tokens.
  stable var totalShares : LPToken = 0;
  /// Mapping of user principals to their LP token balances.
  stable var lpTokenBalances = StableHashMap.new<Principal, LPToken>(
      0,  // initial capacity
      Principal.equal,
      Principal.hash
  );

  // ============================================================================
  //  Types for Operations and Events
  // ============================================================================

  /**
   * Represents the type of token. The variant indicates whether it is TokenA or TokenB.
   */
  type TokenType = { #TokenA; #TokenB; };

  /**
   * Events emitted by the AMM for key actions.
   *
   * @notice Events help off-chain services and front-ends track state changes.
   */
  public type Event = {
    #LiquidityAdded : { caller : Principal; amountA : Nat; amountB : Nat; lpTokens : Nat };
    #LiquidityRemoved : { caller : Principal; amountA : Nat; amountB : Nat; lpTokens : Nat };
    #Swap : { caller : Principal; tokenIn : TokenType; amountIn : Nat; amountOut : Nat };
  };
  /// Buffer for storing events.
  stable var events = Buffer.Buffer<Event>(0);

  // ============================================================================
  //  Core Functions
  // ============================================================================

  /**
   * Computes the expected output amount for a swap given an input amount.
   *
   * @param tokenIn The token being provided as input.
   * @param amountIn The amount of token provided.
   * @return A Result containing either the output TokenAmount on success, or an error message.
   *
   * @dev Uses the constant product invariant (x * y = k) to determine the output,
   *      applying the swap fee to the input amount. This function does not alter state.
   */
  func computeAmountOut(tokenIn: TokenType, amountIn: TokenAmount) : Result.Result<TokenAmount, Text> {
    if (amountIn == 0) {
      return #err("Input amount must be greater than zero.");
    };

    // Determine the input (x) and output (y) pool balances based on token type.
    let (x, y) : (TokenAmount, TokenAmount) = switch (tokenIn) {
      case (#TokenA) { (tokenABalance, tokenBBalance) };
      case (#TokenB) { (tokenBBalance, tokenABalance) };
    };

    if (x == 0 || y == 0) {
      return #err("Insufficient liquidity in the pool.");
    };

    // Apply swap fee: deduct feeBasisPoints from the input.
    let amountInAfterFee = amountIn * (feeDenom - feeBasisPoints) / feeDenom;

    // Calculate the invariant constant k = x * y.
    let k = x * y;
    // New input balance after adding the net input amount.
    let xNew = x + amountInAfterFee;
    // New output balance as per the invariant.
    let yNew = k / xNew;

    if (yNew > y) {
      return #err("Arithmetic error: calculated output would be negative.");
    };

    // The output amount is the decrease in the output side of the pool.
    let amountOut : TokenAmount = y - yNew;
    return #ok(amountOut);
  };

  /**
   * Adds liquidity to the pool.
   *
   * @param amountA The amount of Token A provided.
   * @param amountB The amount of Token B provided.
   * @return A Result with a boolean true if liquidity was added successfully, or an error message.
   *
   * @dev On the initial liquidity addition, LP tokens are minted using the geometric mean of
   *      the provided amounts. For subsequent additions, LP tokens are minted in proportion to the
   *      existing pool ratios.
   */
  public shared ({ caller }) func addLiquidity(amountA: TokenAmount, amountB: TokenAmount)
    : async Result.Result<Bool, Text> {
      
    // Validate non-zero input amounts.
    if (amountA == 0 || amountB == 0) {
      return #err("Amounts must be greater than zero.");
    };

    if (totalShares != 0 && (tokenABalance == 0 || tokenBBalance == 0)) {
      return #err("Invalid pool state: nonzero shares with zero token balance.");
    };

    // Determine the number of LP tokens to mint.
    let newShares : LPToken = if (totalShares == 0) {
      // For initial liquidity, use the geometric mean.
      natSqrt(amountA * amountB)
    } else {
      let sharesFromA = (amountA * totalShares) / tokenABalance;
      let sharesFromB = (amountB * totalShares) / tokenBBalance;
      Nat.min(sharesFromA, sharesFromB)
    };

    if (newShares == 0) {
      return #err("Insufficient liquidity provided.");
    };

    // Update pool balances.
    tokenABalance += amountA;
    tokenBBalance += amountB;
    totalShares += newShares;

    // Update the caller's LP token balance.
    let oldBalance = switch (lpTokenBalances.get(caller)) {
      case (null) { 0 };
      case (?b) { b };
    };
    lpTokenBalances.put(caller, oldBalance + newShares);

    // Emit an event for liquidity addition.
    events.add(#LiquidityAdded { caller = caller; amountA = amountA; amountB = amountB; lpTokens = newShares });

    return #ok(true);
  };

  /**
   * Removes liquidity from the pool.
   *
   * @param lpTokens The number of LP tokens to redeem.
   * @return A Result containing an object with the withdrawn amounts of Token A and Token B, or an error message.
   *
   * @dev The function calculates the proportional share of both tokens for the provided LP tokens,
   *      updates the pool state, and adjusts the user's LP token balance.
   */
  public shared ({ caller }) func removeLiquidity(lpTokens: LPToken)
    : async Result.Result<{ amountA: TokenAmount; amountB: TokenAmount }, Text> {

    if (lpTokens == 0) {
      return #err("Invalid LP token amount: cannot remove zero.");
    };

    let userBalance = lpTokenBalances.get(caller);
    switch (userBalance) {
      case (null) {
        return #err("Insufficient LP tokens: caller does not hold any.");
      };
      case (?balance) {
        if (lpTokens > balance) {
          return #err("Insufficient LP tokens: requested amount exceeds balance.");
        };
        if (totalShares == 0) {
          return #err("Pool is in an invalid state.");
        };

        // Calculate proportional withdrawal amounts.
        let tokenAWithdraw = (lpTokens * tokenABalance) / totalShares;
        let tokenBWithdraw = (lpTokens * tokenBBalance) / totalShares;

        // Update the pool state.
        tokenABalance -= tokenAWithdraw;
        tokenBBalance -= tokenBWithdraw;
        totalShares -= lpTokens;

        // Update the caller's LP token balance.
        let newBalance = balance - lpTokens;
        if (newBalance == 0) {
          lpTokenBalances.delete(caller);
        } else {
          lpTokenBalances.put(caller, newBalance);
        };

        // Emit an event for liquidity removal.
        events.add(#LiquidityRemoved { caller = caller; amountA = tokenAWithdraw; amountB = tokenBWithdraw; lpTokens = lpTokens });

        return #ok({ amountA = tokenAWithdraw; amountB = tokenBWithdraw });
      };
    };
  };

  /**
   * Executes a token swap using the constant product invariant.
   *
   * @param tokenIn The type of token being swapped in.
   * @param amountIn The amount of token being swapped in.
   * @return A Result containing the amount of token swapped out, or an error message.
   *
   * @dev This function calls computeAmountOut to determine the output amount, then updates the pool's
   *      token balances accordingly, and logs the swap event.
   */
  public shared ({ caller }) func swap(tokenIn: TokenType, amountIn: TokenAmount)
    : async Result.Result<TokenAmount, Text> {

    let result = computeAmountOut(tokenIn, amountIn);
    switch (result) {
      case (#ok amountOut) {
        // Update pool balances depending on the token swapped in.
        switch (tokenIn) {
          case (#TokenA) {
            tokenABalance += amountIn;
            tokenBBalance -= amountOut;
          };
          case (#TokenB) {
            tokenBBalance += amountIn;
            tokenABalance -= amountOut;
          };
        };

        // Emit an event for the swap.
        events.add(#Swap { caller = caller; tokenIn = tokenIn; amountIn = amountIn; amountOut = amountOut });
        return #ok(amountOut);
      };
      case (#err errorMsg) {
        return #err(errorMsg);
      };
    };
  };

  /**
   * Returns the current state of the liquidity pool.
   *
   * @return An object containing the balances of Token A, Token B, and the total LP tokens.
   *
   * @dev This query function is used by front-ends or monitoring tools to display pool status.
   */
  public query func getPoolState() : async { tokenABalance: TokenAmount; tokenBBalance: TokenAmount; totalShares: LPToken } {
    return { tokenABalance = tokenABalance; tokenBBalance = tokenBBalance; totalShares = totalShares };
  };

  /**
   * Returns an array of all logged events.
   *
   * @return A list of Event objects that record liquidity additions, removals, and swaps.
   */
  public query func getEvents() : async [Event] {
    return Buffer.toArray(events);
  };

  // ============================================================================
  //  Additional Utility Functions
  // ============================================================================

  /**
   * Returns the LP token balance for a specified principal.
   *
   * @param user The principal for which to retrieve the LP token balance.
   * @return The LP token balance as a Nat.
   *
   * @dev This query function is useful for front-end applications that need to show a user's share in the pool.
   */
  public query func getUserLPBalance(user: Principal) : async LPToken {
    return switch (lpTokenBalances.get(user)) {
      case (null) { 0 };
      case (?balance) { balance };
    };
  };

  /**
   * Simulates a swap operation without modifying the pool state.
   *
   * @param tokenIn The token type provided as input.
   * @param amountIn The amount of token provided.
   * @return A Result with the expected output amount, or an error message if the swap cannot be performed.
   *
   * @dev This function is useful for front-ends that want to display the outcome of a potential swap
   *      before executing it.
   */
  public query func simulateSwap(tokenIn: TokenType, amountIn: TokenAmount) : async Result.Result<TokenAmount, Text> {
    return computeAmountOut(tokenIn, amountIn);
  };

  /**
   * Returns the current price of Token A in terms of Token B.
   *
   * @return The price as a Float. Returns 0.0 if there is insufficient liquidity.
   *
   * @dev The price is calculated as (TokenB balance) / (TokenA balance).
   *      Front-end applications can use this value to display the current exchange rate.
   */
  public query func getPoolPrice() : async Float {
    // Check for sufficient liquidity.
    if (tokenABalance == 0 or tokenBBalance == 0) {
      return 0.0;
    };
    let price = Float.fromInt(Int.fromNat(tokenBBalance)) / Float.fromInt(Int.fromNat(tokenABalance));
    return price;
  };

  /**
   * Updates the fee basis points for swaps.
   *
   * @param newFeeBasisPoints The new fee in basis points.
   * @return A Result with a boolean true if the fee was updated successfully, or an error message.
   *
   * @dev Only the admin is allowed to call this function.
   *      This function includes optional validation to ensure the fee does not exceed a maximum value.
   */
  public shared ({ caller }) func updateFee(newFeeBasisPoints: Nat) : async Result.Result<Bool, Text> {
    // Replace 'admin' check with your actual administrative logic as needed.
    // For example, you might have an admin variable set on instantiation.
    if (caller != Principal.fromActor(this)) {
      return #err("Unauthorized: Only the admin can update the fee.");
    };
    if (newFeeBasisPoints > feeDenom / 2) {
      return #err("Fee is too high.");
    };
    feeBasisPoints := newFeeBasisPoints;
    Debug.print("Fee updated to " # Nat.toText(newFeeBasisPoints) # " basis points.");
    return #ok(true);
  };
};

