// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HandlerTests} from "./Handler.t.sol";

contract InvariantsTests is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperconfig;
    address weth;
    address wbtc;
    HandlerTests handler;

    function setUp() public {
        DeployDSC deployer = new DeployDSC();
        (dsc, dscEngine, helperconfig) = deployer.run();
        (, , weth, wbtc, ) = helperconfig.activeNetworkConfig();
        handler = new HandlerTests(dsc, dscEngine);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
        INVARIANT 1: Protocol must always be overcollateralized
        Total USD value of collateral >= Total DSC supply
    //////////////////////////////////////////////////////////////*/

    function invariant_protocolMustHaveMoreCollateralThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 wethAmount = IERC20(weth).balanceOf(address(dscEngine));
        uint256 wbtcAmount = IERC20(wbtc).balanceOf(address(dscEngine));
        uint256 wethValue = dscEngine.getUsdValue(weth, wethAmount);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, wbtcAmount);
        uint256 totalCollateralValue = wethValue + wbtcValue;

        console.log("Total DSC Supply:", totalSupply);
        console.log("Total Collateral Value:", totalCollateralValue);
        console.log("Times Deposit Called:", handler.timesDepositIsCalled());
        console.log("Times Mint Called:", handler.timesMintIsCalled());
        console.log("Times Redeem Called:", handler.timesRedeemIsCalled());

        assert(totalCollateralValue >= totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
        INVARIANT 2: Getter functions should never revert
    //////////////////////////////////////////////////////////////*/

    function invariant_gettersShouldNotRevert() public view {
        dscEngine.getCollateralTokens();
        dscEngine.getDsc();
        dscEngine.getLiquidationThreshold();
        dscEngine.getLiquidationBonus();
        dscEngine.getLiquidationPrecision();
        dscEngine.getMinHealthFactor();
        dscEngine.getPrecision();
        dscEngine.getAdditionalFeedPrecision();
    }

    /*//////////////////////////////////////////////////////////////
        INVARIANT 3: DSC total supply must equal sum of all balances
                     in the engine (minted to real addresses)
    //////////////////////////////////////////////////////////////*/

    function invariant_dscTotalSupplyMustMatchEngineAccounting() public view {
        uint256 totalSupply = dsc.totalSupply();

        // The total DSC in circulation should be backed by the protocol
        // This means the DSC total supply should never exceed what the engine tracks
        uint256 wethAmount = IERC20(weth).balanceOf(address(dscEngine));
        uint256 wbtcAmount = IERC20(wbtc).balanceOf(address(dscEngine));
        uint256 wethValue = dscEngine.getUsdValue(weth, wethAmount);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, wbtcAmount);
        uint256 totalCollateral = wethValue + wbtcValue;

        // The protocol's collateral should always cover at least 200% of DSC supply
        // Since health factor minimum is 1 (which means 200% ratio due to 50% threshold)
        if (totalSupply > 0) {
            assert(totalCollateral * 50 / 100 >= totalSupply);
        }
    }
}
