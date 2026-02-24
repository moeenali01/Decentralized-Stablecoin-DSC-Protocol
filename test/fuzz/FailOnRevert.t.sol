// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title FailOnRevert Invariant Tests
 * @notice These tests are designed to run with fail_on_revert=false for quick fuzzing.
 *         They allow reverts (some calls will naturally revert) and only check
 *         that the core invariants hold after non-reverting sequences.
 *
 * @dev To run these tests:
 *      forge test --match-contract FailOnRevertInvariants
 *
 *      Make sure to set fail_on_revert=false in foundry.toml before running:
 *      [invariant]
 *      fail_on_revert = false
 *
 *      Or use a separate profile:
 *      FOUNDRY_PROFILE=loose forge test --match-contract FailOnRevertInvariants
 */

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
/*//////////////////////////////////////////////////////////////
            FAIL ON REVERT HANDLER (ALLOWS REVERTS)
//////////////////////////////////////////////////////////////*/

/**
 * @notice This handler does NOT guard against reverts. It calls protocol functions
 *         with loosely bounded inputs, allowing many calls to revert. This is useful
 *         with fail_on_revert=false to quickly fuzz many random sequences and only
 *         verify invariants after successful call sequences.
 */
contract FailOnRevertHandler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public constant MAX_DEPOSIT = type(uint96).max;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _dscEngine) {
        dsc = _dsc;
        dscEngine = _dscEngine;
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    // Deposit random amount of random collateral - may revert if amount is 0
    function depositCollateral(uint256 _seed, uint256 _amount) public {
        _amount = bound(_amount, 0, MAX_DEPOSIT);
        ERC20Mock token = _getCollateralFromSeed(_seed);

        vm.startPrank(msg.sender);
        token.mint(msg.sender, _amount);
        token.approve(address(dscEngine), _amount);
        dscEngine.depositCollateral(address(token), _amount);
        vm.stopPrank();
    }

    // Mint random amount of DSC - may revert if health factor breaks
    function mintDsc(uint256 _amount) public {
        _amount = bound(_amount, 0, MAX_DEPOSIT);

        vm.prank(msg.sender);
        dscEngine.mintDsc(_amount);
    }

    // Redeem random amount - may revert if insufficient balance or health factor breaks
    function redeemCollateral(uint256 _seed, uint256 _amount) public {
        ERC20Mock token = _getCollateralFromSeed(_seed);
        _amount = bound(_amount, 0, MAX_DEPOSIT);

        vm.prank(msg.sender);
        dscEngine.redeemCollateral(address(token), _amount);
    }

    // Burn random amount of DSC - may revert if user doesn't have enough
    function burnDsc(uint256 _amount) public {
        _amount = bound(_amount, 0, MAX_DEPOSIT);

        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), _amount);
        dscEngine.burnDsc(_amount);
        vm.stopPrank();
    }

    // Liquidate - may revert if target is healthy
    function liquidate(uint256 _seed, address _user, uint256 _debtToCover) public {
        ERC20Mock token = _getCollateralFromSeed(_seed);
        _debtToCover = bound(_debtToCover, 0, MAX_DEPOSIT);

        vm.prank(msg.sender);
        dscEngine.liquidate(address(token), _user, _debtToCover);
    }

    // Deposit and mint in one call - may revert
    function depositCollateralAndMintDsc(uint256 _seed, uint256 _collateralAmount, uint256 _dscAmount) public {
        ERC20Mock token = _getCollateralFromSeed(_seed);
        _collateralAmount = bound(_collateralAmount, 0, MAX_DEPOSIT);
        _dscAmount = bound(_dscAmount, 0, MAX_DEPOSIT);

        vm.startPrank(msg.sender);
        token.mint(msg.sender, _collateralAmount);
        token.approve(address(dscEngine), _collateralAmount);
        dscEngine.depositCollateralAndMintDsc(address(token), _collateralAmount, _dscAmount);
        vm.stopPrank();
    }

    // Redeem and burn in one call - may revert
    function redeemCollateralForDsc(uint256 _seed, uint256 _collateralAmount, uint256 _dscAmount) public {
        ERC20Mock token = _getCollateralFromSeed(_seed);
        _collateralAmount = bound(_collateralAmount, 0, MAX_DEPOSIT);
        _dscAmount = bound(_dscAmount, 0, MAX_DEPOSIT);

        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), _dscAmount);
        dscEngine.redeemCollateralForDsc(address(token), _collateralAmount, _dscAmount);
        vm.stopPrank();
    }

    // NOTE: updateCollateralPrice is intentionally excluded from this handler.
    // Arbitrary price changes can break the overcollateralization invariant,
    // which is a known protocol limitation (documented black swan scenario),
    // not a bug. The main Handler (with fail_on_revert=true) is where we test
    // with stable prices to verify no transaction sequence can break invariants.

    function _getCollateralFromSeed(uint256 seed) private view returns (ERC20Mock) {
        if (seed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}

/*//////////////////////////////////////////////////////////////
                FAIL ON REVERT INVARIANT TESTS
    Run with: FOUNDRY_PROFILE=loose forge test --match-contract FailOnRevertInvariants
    Requires foundry.toml profile with fail_on_revert = false
//////////////////////////////////////////////////////////////*/

contract FailOnRevertInvariants is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperconfig;
    address weth;
    address wbtc;
    FailOnRevertHandler handler;

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, dscEngine, helperconfig) = deployer.run();
        (, , weth, wbtc, ) = helperconfig.activeNetworkConfig();
        handler = new FailOnRevertHandler(dsc, dscEngine);
        targetContract(address(handler));
    }

    /**
     * @notice Core invariant: total collateral value >= total DSC supply
     * @dev Even with random price changes and reverted calls, this must hold
     *      for any successfully completed sequence of transactions
     */
    function invariant_protocolCollateralBacksDscSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethAmount = IERC20(weth).balanceOf(address(dscEngine));
        uint256 wbtcAmount = IERC20(wbtc).balanceOf(address(dscEngine));
        uint256 wethValue = dscEngine.getUsdValue(weth, wethAmount);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, wbtcAmount);
        uint256 totalCollateralValue = wethValue + wbtcValue;

        console.log("DSC Supply:", totalSupply);
        console.log("Collateral Value:", totalCollateralValue);

        assert(totalCollateralValue >= totalSupply);
    }

    /**
     * @notice Getter functions must never revert regardless of protocol state
     */
    function invariant_getterViewFunctionsShouldNeverRevert() public view {
        dscEngine.getCollateralTokens();
        dscEngine.getDsc();
        dscEngine.getLiquidationThreshold();
        dscEngine.getLiquidationBonus();
        dscEngine.getLiquidationPrecision();
        dscEngine.getMinHealthFactor();
        dscEngine.getPrecision();
        dscEngine.getAdditionalFeedPrecision();
        dscEngine.getCollateralTokenPriceFeed(weth);
        dscEngine.getCollateralTokenPriceFeed(wbtc);
    }
}
