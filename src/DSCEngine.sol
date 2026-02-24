// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/**
 * =============================================================
 *                          IMPORTS
 * =============================================================
 *
 * OracleLib         → Custom library that wraps Chainlink's latestRoundData()
 *                     with a staleness check. If the price feed hasn't updated
 *                     within a set timeout (e.g., 3 hours), it reverts — preventing
 *                     the protocol from operating on stale/incorrect prices.
 *
 * AggregatorV3Interface → Chainlink's standard interface for reading price feed data.
 *                         Exposes latestRoundData() which returns the current price,
 *                         round ID, and timestamps.
 *
 * ReentrancyGuard   → OpenZeppelin's reentrancy protection. Uses a state lock (_status)
 *                     to prevent a function from being re-entered during an external call.
 *                     Protects against reentrancy attacks (e.g., the 2016 DAO hack pattern).
 *
 * IERC20            → Standard ERC-20 interface. Allows this contract to call
 *                     transferFrom() and transfer() on collateral tokens (WETH, WBTC)
 *                     without needing the full token implementation.
 *
 * DecentralizedStableCoin → The DSC token contract itself. DSCEngine holds minting and
 *                           burning privileges over this token. When users deposit collateral,
 *                           DSCEngine mints DSC to them; when they repay, it burns DSC.
 */
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

/**
 * @title DSCEngine
 * @author Moin Shahid
 *
 * @notice DSCEngine is the core engine of a Decentralized Stablecoin (DSC) system.
 *         It manages all protocol logic: depositing/withdrawing collateral, minting/burning DSC,
 *         and liquidating undercollateralized positions to maintain system solvency.
 *
 * @notice This contract is inspired by the MakerDAO DSS (DAI Stablecoin System),
 *         but intentionally simplified — no governance, no stability fees,
 *         and collateral is limited to WETH and WBTC.
 *
 * @dev System Properties:
 *      - Exogenously Collateralized: Backed by external assets (WETH, WBTC), not by the protocol's own token.
 *      - Dollar Pegged: 1 DSC is designed to always equal $1 USD.
 *      - Algorithmically Stable: Stability is maintained through overcollateralization and liquidation incentives,
 *        not through a central authority or reserve.
 *
 * @dev Core Invariant:
 *      The total USD value of ALL collateral in the system must ALWAYS exceed the total DSC minted.
 *      This invariant is enforced per-user via the health factor mechanism and globally through liquidations.
 *
 * @dev Overcollateralization Requirement:
 *      Users must maintain at least 200% collateralization ratio at all times.
 *      Example: To mint 1,000 DSC ($1,000), a user needs at least $2,000 worth of collateral.
 *      If the ratio drops below 200%, the position becomes liquidatable.
 */
contract DSCEngine is ReentrancyGuard {
    /**
     * =============================================================
     *                       CUSTOM ERRORS
     * =============================================================
     *
     * @dev Custom errors (Solidity 0.8.4+) are used instead of require() strings.
     *      They are significantly cheaper in gas because they use 4-byte selectors
     *      instead of storing full revert strings in bytecode.
     *
     *      Naming convention: ContractName__ErrorDescription
     *      This makes it easy to trace which contract threw the error in a complex system.
     */
    /// @dev Thrown in constructor if tokenAddresses[] and priceFeedAddresses[] have different lengths.
    ///      These arrays must be parallel (index 0 of tokens maps to index 0 of feeds).
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();

    /// @dev Thrown when a user tries to deposit, mint, redeem, or burn with amount = 0.
    ///      Zero-value operations waste gas and could create confusing protocol state.
    error DSCEngine__NeedsMoreThanZero();

    /// @dev Thrown when a user tries to use a collateral token that isn't whitelisted.
    ///      Only tokens registered in the constructor (with valid price feeds) are accepted.
    error DSCEngine__TokenNotAllowed(address token);

    /// @dev Thrown when an ERC-20 transfer() or transferFrom() returns false.
    ///      Some ERC-20 tokens return false instead of reverting on failure.
    error DSCEngine__TransferFailed();

    /// @dev Thrown when an operation (mint, redeem, etc.) would push a user's health factor below 1.0.
    ///      Includes the computed health factor value for debugging and logging.
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);

    /// @dev Thrown if the DSC token's mint() function returns false. This is a safety check —
    ///      in practice, the DecentralizedStableCoin contract should always return true or revert.
    error DSCEngine__MintFailed();

    /// @dev Thrown in liquidate() if the target user's health factor is already >= 1.0.
    ///      You can only liquidate undercollateralized positions.
    error DSCEngine__HealthFactorOk();

    /// @dev Thrown in liquidate() if the liquidation didn't improve the user's health factor.
    ///      This is a safety invariant — should theoretically never trigger, but prevents
    ///      edge cases where liquidation could somehow make things worse.
    error DSCEngine__HealthFactorNotImproved();

    /**
     * =============================================================
     *                      TYPE DECLARATIONS
     * =============================================================
     */

    /**
     * @dev Attaches all functions from OracleLib to the AggregatorV3Interface type.
     *
     *      This enables the syntax:
     *        priceFeed.staleCheckLatestRoundData()
     *      instead of:
     *        OracleLib.staleCheckLatestRoundData(priceFeed)
     *
     *      The priceFeed variable is automatically passed as the first argument.
     *      This is Solidity's "using...for" pattern — syntactic sugar that makes
     *      library calls feel like method calls on the type.
     */
    using OracleLib for AggregatorV3Interface;

    /**
     * =============================================================
     *                       STATE VARIABLES
     * =============================================================
     */

    /**
     * @dev Reference to the DSC token contract.
     *      This contract has owner/minter privileges over DSC, allowing it to
     *      mint new tokens (when users borrow) and burn tokens (when users repay).
     *
     *      Marked `immutable` — set once in the constructor and embedded in bytecode.
     *      Reading an immutable costs 0 gas (equivalent to a constant).
     *      The `i_` prefix is a naming convention indicating immutability.
     */
    DecentralizedStableCoin private immutable i_dsc;

    /**
     * @dev LIQUIDATION_THRESHOLD = 50 means a user's collateral is only "counted" at 50% of its value.
     *      This enforces 200% overcollateralization.
     *
     *      Math: If you deposit $10,000 of ETH, your effective borrowing power is:
     *            $10,000 × (50/100) = $5,000
     *            So you can mint at most 5,000 DSC → $10,000/$5,000 = 200% ratio.
     */
    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    /**
     * @dev LIQUIDATION_BONUS = 10 gives liquidators a 10% bonus on seized collateral.
     *      This incentivizes external actors (bots, traders) to monitor the protocol
     *      and liquidate unhealthy positions quickly, keeping the system solvent.
     *
     *      Example: Liquidator covers $100 of debt → receives $110 worth of collateral.
     */
    uint256 private constant LIQUIDATION_BONUS = 10;

    /**
     * @dev Denominator for percentage calculations involving LIQUIDATION_THRESHOLD and LIQUIDATION_BONUS.
     *      LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION = 50 / 100 = 50%
     *      LIQUIDATION_BONUS / LIQUIDATION_PRECISION     = 10 / 100 = 10%
     */
    uint256 private constant LIQUIDATION_PRECISION = 100;

    /**
     * @dev The minimum acceptable health factor, represented as 1.0 in 18-decimal fixed-point.
     *      A health factor below this means the user is undercollateralized and can be liquidated.
     *      Using 1e18 because Solidity has no floating-point — 1.0 is stored as 1,000,000,000,000,000,000.
     */
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    /**
     * @dev Standard 18-decimal precision multiplier, matching ETH's wei denomination.
     *      Used throughout the contract to maintain consistent fixed-point arithmetic.
     *      Example: $2,000 USD is stored as 2000 * 1e18 = 2,000,000,000,000,000,000,000
     */
    uint256 private constant PRECISION = 1e18;

    /**
     * @dev Chainlink price feeds return prices with 8 decimal places (e.g., ETH at $2,000 = 200000000000).
     *      To normalize to 18 decimals (matching wei), we multiply by 1e10.
     *      8 decimals (Chainlink) + 10 decimals (this multiplier) = 18 decimals (our standard).
     */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    /**
     * @dev Chainlink's native precision — 1e8 (8 decimal places).
     *      Stored as a named constant for clarity, though primarily ADDITIONAL_FEED_PRECISION is used.
     */
    uint256 private constant FEED_PRECISION = 1e8;

    /**
     * @dev Maps each allowed collateral token address → its Chainlink USD price feed address.
     *
     *      Example:
     *        s_priceFeeds[WETH_address] = ETH_USD_Chainlink_Feed
     *        s_priceFeeds[WBTC_address] = BTC_USD_Chainlink_Feed
     *
     *      Used for:
     *        1. Token whitelist check — if s_priceFeeds[token] == address(0), the token isn't allowed.
     *        2. Price lookups — to convert collateral amounts to USD values.
     *
     *      Why a mapping? O(1) lookup time. When checking if a token is allowed or fetching its price,
     *      we don't want to iterate through an array.
     */
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;

    /**
     * @dev Nested mapping tracking each user's deposited collateral amounts per token.
     *
     *      Structure: user address → (token address → deposited amount in token's smallest unit)
     *
     *      Example state:
     *        s_collateralDeposited[Alice][WETH] = 5e18     (5 WETH, in wei)
     *        s_collateralDeposited[Alice][WBTC] = 100000000 (1 WBTC, 8 decimals)
     *        s_collateralDeposited[Bob][WETH]   = 10e18    (10 WETH)
     *
     *      Why a nested mapping instead of a struct or array?
     *        - O(1) read/write for any (user, token) pair.
     *        - No iteration needed for individual lookups.
     *        - Gas efficient — only touched slots cost gas.
     */
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;

    /**
     * @dev Tracks total DSC debt (minted amount) per user.
     *
     *      This is compared against collateral value to compute the health factor.
     *      When a user mints DSC, this increases; when they burn DSC, it decreases.
     *
     *      Example: s_DSCMinted[Alice] = 4000e18 means Alice has minted 4,000 DSC.
     */
    mapping(address user => uint256 amount) private s_DSCMinted;

    /**
     * @dev Array of all whitelisted collateral token addresses.
     *
     *      Needed because Solidity mappings are NOT iterable. When calculating a user's
     *      total collateral value (getAccountCollateralValue), we must loop through all
     *      possible collateral tokens — this array enables that.
     *
     *      Design pattern: Mapping (s_priceFeeds) for O(1) lookups + Array (s_collateralTokens)
     *      for iteration. This is a very common Solidity pattern.
     */
    address[] private s_collateralTokens;

    /**
     * =============================================================
     *                           EVENTS
     * =============================================================
     *
     * @dev Events are log entries stored on the blockchain (NOT in contract storage — much cheaper).
     *      They serve two purposes:
     *        1. Off-chain indexing: Front-ends and subgraphs (The Graph) listen for these
     *           to update UIs in real time.
     *        2. Permanent audit trail: Every deposit/redemption is immutably logged.
     *
     *      The `indexed` keyword (max 3 per event) creates searchable "topics" that allow
     *      efficient log filtering. Example: "show all deposits by address 0xABC..."
     */

    /// @dev Emitted when a user deposits collateral into the protocol.
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /// @dev Emitted when collateral is redeemed (withdrawn). If redeemFrom != redeemTo,
    ///      the redemption was triggered by a liquidation (collateral moved from user to liquidator).
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

    /**
     * =============================================================
     *                          MODIFIERS
     * =============================================================
     *
     * @dev Modifiers are reusable precondition checks that wrap function bodies.
     *      The `_;` placeholder indicates where the actual function code executes.
     *      Execution order: modifier logic before `_;` → function body → modifier logic after `_;` (if any).
     */

    /**
     * @dev Reverts if the provided amount is zero.
     *      Applied to all deposit, mint, redeem, burn, and liquidation functions.
     *      Prevents wasted gas and meaningless state changes.
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    /**
     * @dev Reverts if the provided token address is not a registered collateral type.
     *      A token is "allowed" if it has a non-zero price feed address in s_priceFeeds
     *      (set during construction). Unregistered tokens default to address(0).
     *      This acts as the protocol's collateral whitelist.
     */
    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    /**
     * =============================================================
     *                         CONSTRUCTOR
     * =============================================================
     */

    /**
     * @notice Initializes the DSCEngine with supported collateral tokens, their price feeds, and the DSC token.
     *
     * @param tokenAddresses     Array of ERC-20 collateral token addresses (e.g., [WETH, WBTC]).
     * @param priceFeedAddresses Array of Chainlink price feed addresses, parallel to tokenAddresses
     *                           (e.g., [ETH/USD feed, BTC/USD feed]).
     * @param dscAddress         Address of the deployed DecentralizedStableCoin (DSC) token contract.
     *
     * @dev The two arrays MUST be the same length and in matching order:
     *      tokenAddresses[0] maps to priceFeedAddresses[0], etc.
     *
     * @dev This constructor populates two data structures:
     *      1. s_priceFeeds mapping — for O(1) price feed lookups and token whitelist checks.
     *      2. s_collateralTokens array — for iterating over all collateral types when computing totals.
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // Validate that every token has a corresponding price feed (parallel array requirement)
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }

        // Register each token-priceFeed pair.
        // These feeds must be USD-denominated pairs (e.g., ETH/USD, BTC/USD).
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; // Mapping for O(1) lookup
            s_collateralTokens.push(tokenAddresses[i]); // Array for iteration
        }

        // Store the DSC token reference as immutable (baked into bytecode, 0 gas reads)
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * =============================================================
     *                      EXTERNAL FUNCTIONS
     * =============================================================
     *
     * @dev `external` visibility is used for functions only called from outside the contract.
     *      External functions read calldata directly (cheaper than `public` which copies to memory),
     *      making them more gas-efficient for functions with array/struct parameters.
     */

    /**
     * @notice Deposits collateral and mints DSC in a single atomic transaction.
     *
     * @param tokenCollateralAddress The ERC-20 token to deposit as collateral (must be whitelisted).
     * @param amountCollateral       The amount of collateral to deposit (in the token's smallest unit).
     * @param amountDscToMint        The amount of DSC to mint against the deposited collateral.
     *
     * @dev This is a convenience function combining depositCollateral() + mintDsc().
     *      Atomicity guarantee: if either sub-call fails, the entire transaction reverts.
     *      Saves the user gas vs. two separate transactions and eliminates the risk of
     *      depositing collateral but failing to mint (or vice versa) due to gas issues.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Burns DSC debt and redeems (withdraws) collateral in a single transaction.
     *
     * @param tokenCollateralAddress The ERC-20 collateral token to withdraw.
     * @param amountCollateral       The amount of collateral to redeem.
     * @param amountDscToBurn        The amount of DSC to burn (reducing the user's debt).
     *
     * @dev Burns DSC first (reducing debt), then redeems collateral, then checks health factor.
     *      Order matters: burning debt first makes it more likely the health factor check passes.
     *      The health factor is checked AFTER both operations to ensure the user remains solvent.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Redeems (withdraws) collateral from the protocol.
     *
     * @param tokenCollateralAddress The ERC-20 collateral token to withdraw.
     * @param amountCollateral       The amount to withdraw (in the token's smallest unit).
     *
     * @dev If the user has outstanding DSC debt, this will only succeed if the remaining
     *      collateral still satisfies the 200% overcollateralization requirement.
     *      The health factor check at the end enforces this — if removing collateral
     *      drops the health factor below 1.0, the entire transaction reverts.
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Burns DSC tokens to reduce the caller's debt.
     *
     * @param amount The amount of DSC to burn.
     *
     * @dev Use case: A user who is worried about getting liquidated (e.g., collateral price is falling)
     *      can proactively burn DSC to improve their health factor, without withdrawing any collateral.
     *
     * @dev The health factor check after burning should theoretically never fail — burning debt
     *      can only improve or maintain the health factor, never worsen it. It's included as a
     *      defense-in-depth safety measure.
     */
    function burnDsc(uint256 amount) external moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // Defensive check — should never revert here
    }

    /**
     * @notice Liquidates an undercollateralized user's position.
     *
     * @param collateral  The ERC-20 collateral token to seize from the undercollateralized user.
     * @param user        The address of the undercollateralized user to liquidate.
     * @param debtToCover The amount of DSC debt to repay on behalf of the user.
     *
     * @dev Liquidation Flow:
     *      1. Verify the target user's health factor is below MIN_HEALTH_FACTOR (undercollateralized).
     *      2. Calculate how much collateral equals the debtToCover in USD terms.
     *      3. Add a 10% bonus to incentivize the liquidator.
     *      4. Transfer collateral from the user to the liquidator (via _redeemCollateral).
     *      5. Burn the liquidator's DSC to reduce the user's debt (via _burnDsc).
     *      6. Verify the user's health factor improved (safety invariant).
     *      7. Verify the liquidator's own health factor is still healthy.
     *
     * @dev Partial liquidation is supported — the liquidator doesn't have to cover all the user's debt.
     *
     * @dev Known limitation: If the protocol becomes exactly 100% collateralized (or less),
     *      there's no bonus to extract, so liquidators have no economic incentive to act.
     *      This could happen in a severe, sudden price crash (black swan event).
     *
     * @dev The protocol assumes ~150% average collateralization for liquidations to be profitable.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        isAllowedToken(collateral)
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Step 1: Verify the target user is actually undercollateralized
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // Step 2: Convert the DSC debt amount to its equivalent in collateral tokens
        // Example: If debtToCover = 100 DSC and ETH = $2,000, then tokenAmount = 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // Step 3: Calculate the 10% liquidation bonus
        // Example: 0.05 ETH * 10 / 100 = 0.005 ETH bonus
        // Liquidator receives 0.055 ETH total ($110 worth) for covering $100 of debt
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        // Step 4: Seize collateral (debt equivalent + bonus) from user, send to liquidator
        _redeemCollateral(collateral, tokenAmountFromDebtCovered + bonusCollateral, user, msg.sender);

        // Step 5: Burn DSC from the liquidator to reduce the user's debt
        // Note: onBehalfOf = user (their debt decreases), dscFrom = msg.sender (liquidator pays)
        _burnDsc(debtToCover, user, msg.sender);

        // Step 6: Safety invariant — ensure the liquidation actually helped the user's position
        // This should always pass but guards against edge cases or future code changes
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // Step 7: Ensure the liquidator themselves didn't become undercollateralized
        // (relevant if the liquidator is also a borrower in this protocol)
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * =============================================================
     *                       PUBLIC FUNCTIONS
     * =============================================================
     *
     * @dev `public` functions can be called both externally and internally.
     *      mintDsc and depositCollateral are `public` (not `external`) because they are
     *      called internally by depositCollateralAndMintDsc(). If they were `external`,
     *      the combined function couldn't call them with `this.mintDsc()` pattern efficiently.
     */

    /**
     * @notice Mints DSC stablecoin tokens to the caller.
     *
     * @param amountDscToMint The amount of DSC to mint.
     *
     * @dev Minting flow (Optimistic Update Pattern):
     *      1. Optimistically increase the user's debt record.
     *      2. Check if the health factor is still valid with the new debt.
     *         - If not, the EVM automatically reverts ALL state changes (including step 1).
     *      3. Only if healthy: actually mint the DSC tokens to the user.
     *
     * @dev The user must already have deposited sufficient collateral to maintain
     *      a health factor ≥ 1.0 after this mint. Otherwise the transaction reverts.
     *
     * @dev Example: User has $10,000 collateral → max mintable = $5,000 DSC (at 200% ratio).
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // Optimistically add to the user's debt (will be undone by revert if health factor breaks)
        s_DSCMinted[msg.sender] += amountDscToMint;

        // Revert the entire transaction if this mint would make the user undercollateralized
        _revertIfHealthFactorIsBroken(msg.sender);

        // If health factor is OK, actually mint the DSC tokens to the user
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (minted != true) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @notice Deposits ERC-20 collateral tokens into the protocol.
     *
     * @param tokenCollateralAddress The address of the ERC-20 token to deposit (must be whitelisted).
     * @param amountCollateral       The amount to deposit (in the token's smallest unit, e.g., wei for WETH).
     *
     * @dev Prerequisites: The caller must have already approved this contract to spend
     *      `amountCollateral` of the token via token.approve(DSCEngine_address, amount).
     *
     * @dev Follows the Checks-Effects-Interactions (CEI) security pattern:
     *      CHECKS:       moreThanZero, nonReentrant, isAllowedToken (modifiers)
     *      EFFECTS:      Update s_collateralDeposited mapping, emit event
     *      INTERACTIONS: Call transferFrom on the external ERC-20 token (last!)
     *
     *      CEI prevents reentrancy exploits: even if the external token contract tries to
     *      re-enter this function during transferFrom, the state is already updated correctly.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        // EFFECT: Update internal bookkeeping BEFORE the external call (CEI pattern)
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        // EFFECT: Log the deposit for off-chain indexing and audit trail
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        // INTERACTION: Pull tokens from user into this contract (requires prior approval)
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * =============================================================
     *                       PRIVATE FUNCTIONS
     * =============================================================
     *
     * @dev Private functions are only callable within this contract (not even by derived contracts).
     *      They contain shared logic used by multiple external/public functions.
     */

    /**
     * @notice Internal logic for redeeming (withdrawing) collateral.
     *
     * @param tokenCollateralAddress The collateral token to transfer.
     * @param amountCollateral       The amount to transfer.
     * @param from                   The user whose collateral balance decreases.
     * @param to                     The recipient of the collateral tokens.
     *
     * @dev This private function supports TWO use cases via its from/to parameters:
     *      1. Normal redemption: from = msg.sender, to = msg.sender (user withdraws own collateral)
     *      2. Liquidation:       from = undercollateralized_user, to = liquidator (collateral seized)
     *
     * @dev Solidity 0.8+ has built-in underflow protection. If amountCollateral exceeds
     *      the user's deposited balance, the subtraction automatically reverts — no SafeMath needed.
     *
     * @dev Follows CEI: state update → event → external transfer
     */
    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        // EFFECT: Decrease the depositor's balance (auto-reverts on underflow in Solidity 0.8+)
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;

        // EFFECT: Log the redemption (from != to indicates a liquidation occurred)
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        // INTERACTION: Transfer the actual tokens to the recipient
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Internal logic for burning DSC to reduce a user's debt.
     *
     * @param amountDscToBurn The amount of DSC to burn.
     * @param onBehalfOf      The user whose debt record decreases.
     * @param dscFrom         The address from which DSC tokens are pulled (must have approved this contract).
     *
     * @dev Two use cases via parameters:
     *      1. Normal burn:  onBehalfOf = msg.sender, dscFrom = msg.sender (user repays own debt)
     *      2. Liquidation:  onBehalfOf = undercollateralized_user (debt decreases),
     *                       dscFrom = liquidator (they provide the DSC)
     *
     * @dev Flow:
     *      1. Decrease the debt record for onBehalfOf.
     *      2. Pull DSC tokens from dscFrom into this contract.
     *      3. Permanently burn the DSC tokens (removes them from total supply).
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        // Reduce the debt record (auto-reverts on underflow if burning more than owed)
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        // Pull DSC tokens from the payer into this contract
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // This conditional is hypothetically unreachable — transferFrom should revert on failure,
        // not return false. Included as defense-in-depth.
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        // Permanently destroy the tokens, reducing total DSC supply
        i_dsc.burn(amountDscToBurn);
    }

    /**
     * =============================================================
     *            PRIVATE & INTERNAL VIEW / PURE FUNCTIONS
     * =============================================================
     */

    /**
     * @notice Retrieves a user's total DSC debt and total collateral value in USD.
     *
     * @param user The address to query.
     * @return totalDscMinted        The user's total DSC debt.
     * @return collateralValueInUsd  The user's total collateral value in USD (18 decimals).
     *
     * @dev This is the primary data source for health factor calculations.
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice Calculates the health factor for a given user.
     *
     * @param user The address to evaluate.
     * @return The user's health factor as an 18-decimal fixed-point number.
     *
     * @dev Health factor formula:
     *      HF = (collateralValueInUsd × LIQUIDATION_THRESHOLD / 100) × 1e18 / totalDscMinted
     *
     *      HF ≥ 1e18 (1.0) → User is safe
     *      HF < 1e18 (1.0) → User is undercollateralized and can be liquidated
     *      HF = type(uint256).max → User has no debt (division by zero protection)
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @notice Converts a token amount to its USD value using the Chainlink price feed.
     *
     * @param token  The collateral token address.
     * @param amount The token amount (in the token's smallest unit, e.g., wei).
     * @return The USD value as an 18-decimal fixed-point number.
     *
     * @dev Math breakdown:
     *      1. Fetch price from Chainlink (8 decimals). E.g., ETH at $2,000 → 200000000000
     *      2. Scale to 18 decimals: price × 1e10 = 2000000000000000000000
     *      3. Multiply by amount: 2000e18 × amount
     *      4. Divide by 1e18 to normalize: result in 18-decimal USD
     *
     *      Example: 5 ETH at $2,000
     *        = (200000000000 × 1e10 × 5e18) / 1e18
     *        = 10,000e18 ($10,000)
     */
    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);

        // Uses OracleLib's staleCheckLatestRoundData() (attached via `using OracleLib for`).
        // This reverts if the price data is stale, preventing operations on outdated prices.
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        // Scale Chainlink's 8-decimal price to 18 decimals, multiply by amount, normalize
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice Pure math function to calculate health factor from raw values.
     *
     * @param totalDscMinted        The user's total DSC debt.
     * @param collateralValueInUsd  The user's total collateral value in USD (18 decimals).
     * @return The health factor as an 18-decimal fixed-point number.
     *
     * @dev Marked `internal` (not `private`) to allow derived contracts to override
     *      the health factor calculation if needed (e.g., different threshold logic).
     *
     * @dev If totalDscMinted is 0, returns type(uint256).max to avoid division by zero
     *      and to indicate the user has infinite health (no debt = can never be liquidated).
     *
     * @dev Math:
     *      1. Adjust collateral by threshold: collateral × 50 / 100 (only 50% "counts")
     *      2. Scale and divide by debt: (adjusted × 1e18) / dscMinted
     *
     *      Example: $10,000 collateral, 4,000 DSC debt
     *        Step 1: $10,000 × 50/100 = $5,000 (adjusted collateral)
     *        Step 2: ($5,000 × 1e18) / $4,000 = 1.25e18 (health factor = 1.25, safe)
     */
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        // No debt means infinite health — user cannot be liquidated
        if (totalDscMinted == 0) return type(uint256).max;

        // Apply the liquidation threshold: only 50% of collateral value counts as borrowing power
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // Calculate and return the health factor in 18-decimal fixed-point
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @notice Reverts the transaction if the user's health factor is below the minimum.
     *
     * @param user The address to check.
     *
     * @dev This is the protocol's primary solvency enforcement mechanism.
     *      Called after every state-changing operation (mint, redeem, burn, liquidate)
     *      to ensure no operation leaves a user undercollateralized.
     *
     * @dev Marked `internal` (not `private`) to allow derived contracts to call it,
     *      enabling extensibility for future versions.
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /**
     * =============================================================
     *          EXTERNAL & PUBLIC VIEW / PURE FUNCTIONS
     * =============================================================
     *
     * @dev These are read-only getter functions that expose private/internal state.
     *      They cost ZERO gas when called off-chain (via eth_call) and are essential for:
     *        - Front-end UIs to display user positions
     *        - Liquidation bots to monitor health factors
     *        - Analytics dashboards to track protocol health
     *
     *      State variables are kept `private` to prevent external contracts from
     *      depending on storage layout (which could break during upgrades).
     *      These getters provide a stable, versioned API.
     */

    /// @notice Public wrapper for _calculateHealthFactor. Useful for off-chain simulations.
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /// @notice Returns a user's total DSC debt and total collateral value in USD.
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    /// @notice Returns the USD value of a given token amount (18-decimal fixed-point).
    function getUsdValue(
        address token,
        uint256 amount // in WEI
    )
        external
        view
        returns (uint256)
    {
        return _getUsdValue(token, amount);
    }

    /// @notice Returns how much of a specific collateral token a user has deposited.
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    /**
     * @notice Calculates the total USD value of all collateral deposited by a user.
     *
     * @param user The address to query.
     * @return totalCollateralValueInUsd The sum of all collateral values in USD (18 decimals).
     *
     * @dev Iterates through s_collateralTokens array (this is why we need the array alongside
     *      the mapping — mappings cannot be iterated in Solidity).
     *      For each token, looks up the user's deposited amount and converts to USD via the price feed.
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @notice Converts a USD amount to its equivalent in collateral tokens.
     *
     * @param token           The collateral token to convert to.
     * @param usdAmountInWei  The USD amount (18-decimal fixed-point).
     * @return The equivalent token amount in the token's smallest unit.
     *
     * @dev This is the inverse of _getUsdValue(). Used primarily in liquidation
     *      to determine how many collateral tokens correspond to the debt being covered.
     *
     * @dev Math (inverse of _getUsdValue):
     *      tokenAmount = (usdAmount × 1e18) / (price × 1e10)
     *
     *      Example: $2,000 USD worth of ETH at $2,000/ETH
     *        = (2000e18 × 1e18) / (200000000000 × 1e10)
     *        = (2000e18 × 1e18) / (2000e18)
     *        = 1e18 (= 1 ETH)
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    /// @notice Returns the standard 18-decimal precision constant (1e18).
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    /// @notice Returns the additional precision multiplier for Chainlink feeds (1e10).
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    /// @notice Returns the liquidation threshold (50 = 50% = 200% collateralization required).
    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    /// @notice Returns the liquidation bonus percentage (10 = 10% bonus for liquidators).
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    /// @notice Returns the precision denominator for liquidation calculations (100).
    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    /// @notice Returns the minimum health factor (1e18 = 1.0).
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /// @notice Returns the array of all whitelisted collateral token addresses.
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /// @notice Returns the address of the DSC stablecoin token contract.
    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    /// @notice Returns the Chainlink price feed address for a given collateral token.
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    /// @notice Returns the current health factor for a user (18-decimal fixed-point).
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
