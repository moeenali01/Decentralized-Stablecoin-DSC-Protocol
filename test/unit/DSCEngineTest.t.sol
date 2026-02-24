// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperconfig;
    address wethUSDPriceFeed;
    address wbtcUSDPriceFeed;
    address weth;
    address wbtc;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperconfig) = deployer.run();
        (wethUSDPriceFeed, wbtcUSDPriceFeed, weth, wbtc,) = helperconfig.activeNetworkConfig();
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertIfTokenLengthNotMatchedPriceFeeds() public {
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = weth;
        tokenAddresses[1] = wbtc;
        address[] memory priceFeedAddresses = new address[](1);
        priceFeedAddresses[0] = wethUSDPriceFeed;
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testConstructorSetsCollateralTokensCorrectly() public view {
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens.length, 2);
        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);
    }

    function testConstructorSetsPriceFeedsCorrectly() public view {
        address feedForWeth = dscEngine.getCollateralTokenPriceFeed(weth);
        address feedForWbtc = dscEngine.getCollateralTokenPriceFeed(wbtc);
        assertEq(feedForWeth, wethUSDPriceFeed);
        assertEq(feedForWbtc, wbtcUSDPriceFeed);
    }

    function testConstructorSetsDscAddress() public view {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE FEED TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsdValue = 30_000e18;
        uint256 actualUsdValue = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetUsdValueForBtc() public view {
        uint256 btcAmount = 10e18;
        // BTC price = 1000e8
        uint256 expectedUsdValue = 10_000e18;
        uint256 actualUsdValue = dscEngine.getUsdValue(wbtc, btcAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 30_000e18;
        uint256 expectedEthAmount = 15e18;
        uint256 actualEthAmount = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedEthAmount, actualEthAmount);
    }

    function testGetTokenAmountFromUsdForBtc() public view {
        uint256 usdAmount = 5_000e18;
        // BTC price = 1000e8, so 5000 USD = 5 BTC
        uint256 expectedBtcAmount = 5e18;
        uint256 actualBtcAmount = dscEngine.getTokenAmountFromUsd(wbtc, usdAmount);
        assertEq(expectedBtcAmount, actualBtcAmount);
    }

    /*//////////////////////////////////////////////////////////////
                         DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), 10e18);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock unapprovedToken = new ERC20Mock("Unapproved Token", "UT", user, 1000e18);
        vm.startPrank(user);
        unapprovedToken.approve(address(dscEngine), 10e18);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(unapprovedToken)));
        dscEngine.depositCollateral(address(unapprovedToken), 10e18);
        vm.stopPrank();
    }

    function testDepositCollateralAndGetInformation() public depositedCollateral {
        (uint256 totalDscMinted, uint256 totalCollateralValue) = dscEngine.getAccountInformation(user);
        uint256 expectedCollateralValueInUsd = dscEngine.getUsdValue(weth, amountCollateral);
        assertEq(expectedCollateralValueInUsd, totalCollateralValue);
        assertEq(totalDscMinted, 0);
    }

    function testDepositCollateralEmitsEvent() public {
        deal(weth, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        vm.expectEmit(true, true, true, false, address(dscEngine));
        emit CollateralDeposited(user, weth, amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    function testDepositCollateralTransfersTokens() public depositedCollateral {
        uint256 engineBalance = ERC20Mock(weth).balanceOf(address(dscEngine));
        assertEq(engineBalance, amountCollateral);
    }

    function testDepositCollateralUpdatesUserBalance() public depositedCollateral {
        uint256 userCollateral = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(userCollateral, amountCollateral);
    }

    function testCanDepositMultipleCollateralTypes() public depositedCollateral {
        // Also deposit WBTC
        deal(wbtc, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(wbtc).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(wbtc, amountCollateral);
        vm.stopPrank();

        uint256 wethBalance = dscEngine.getCollateralBalanceOfUser(user, weth);
        uint256 wbtcBalance = dscEngine.getCollateralBalanceOfUser(user, wbtc);
        assertEq(wethBalance, amountCollateral);
        assertEq(wbtcBalance, amountCollateral);
    }

    /*//////////////////////////////////////////////////////////////
                              MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertMintDscWithZeroAmount() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertMintDscWithoutCollateral() public {
        vm.startPrank(user);
        vm.expectRevert(); // DSCEngine__BreaksHealthFactor
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testMintDscSuccess() public depositedCollateral {
        vm.prank(user);
        dscEngine.mintDsc(amountToMint);

        uint256 userDscBalance = dsc.balanceOf(user);
        assertEq(userDscBalance, amountToMint);
    }

    function testMintDscUpdatesDebtRecord() public depositedCollateral {
        vm.prank(user);
        dscEngine.mintDsc(amountToMint);

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(totalDscMinted, amountToMint);
    }

    function testRevertMintDscBreaksHealthFactor() public depositedCollateral {
        // 10 ETH at $2000 = $20,000 collateral
        // Max mintable at 200% = $10,000 DSC
        // Try to mint $10,001 DSC -> should revert
        uint256 tooMuchDsc = 10_001e18;
        vm.startPrank(user);
        vm.expectRevert(); // DSCEngine__BreaksHealthFactor
        dscEngine.mintDsc(tooMuchDsc);
        vm.stopPrank();
    }

    function testCanMintMaxDsc() public depositedCollateral {
        // 10 ETH at $2000 = $20,000 collateral
        // Max mintable at 200% = $10,000 DSC
        uint256 maxDsc = 10_000e18;
        vm.prank(user);
        dscEngine.mintDsc(maxDsc);

        uint256 userDscBalance = dsc.balanceOf(user);
        assertEq(userDscBalance, maxDsc);
    }

    /*//////////////////////////////////////////////////////////////
                              BURN DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertBurnDscWithZeroAmount() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testBurnDscSuccess() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userDscBalance = dsc.balanceOf(user);
        assertEq(userDscBalance, 0);
    }

    function testBurnDscReducesDebt() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.burnDsc(amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(totalDscMinted, 0);
    }

    function testCanBurnPartialDsc() public depositedCollateralAndMintedDsc {
        uint256 burnAmount = 50 ether;
        vm.startPrank(user);
        dsc.approve(address(dscEngine), burnAmount);
        dscEngine.burnDsc(burnAmount);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(totalDscMinted, amountToMint - burnAmount);
    }

    function testRevertBurnMoreThanMinted() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint + 1);
        vm.expectRevert(); // underflow
        dscEngine.burnDsc(amountToMint + 1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    DEPOSIT COLLATERAL AND MINT DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testDepositCollateralAndMintDscSuccess() public {
        deal(weth, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 totalCollateralValue) = dscEngine.getAccountInformation(user);
        uint256 expectedCollateralValueInUsd = dscEngine.getUsdValue(weth, amountCollateral);
        assertEq(totalDscMinted, amountToMint);
        assertEq(totalCollateralValue, expectedCollateralValueInUsd);
    }

    function testRevertDepositCollateralAndMintDscBreaksHealthFactor() public {
        deal(weth, user, amountCollateral);
        uint256 tooMuchDsc = 10_001e18;
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        vm.expectRevert(); // DSCEngine__BreaksHealthFactor
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, tooMuchDsc);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertRedeemCollateralZeroAmount() public depositedCollateral {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRedeemCollateralSuccess() public depositedCollateral {
        vm.prank(user);
        dscEngine.redeemCollateral(weth, amountCollateral);

        uint256 userCollateral = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(userCollateral, 0);
    }

    function testRedeemCollateralTransfersTokensBack() public depositedCollateral {
        uint256 userBalanceBefore = ERC20Mock(weth).balanceOf(user);
        vm.prank(user);
        dscEngine.redeemCollateral(weth, amountCollateral);

        uint256 userBalanceAfter = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalanceAfter - userBalanceBefore, amountCollateral);
    }

    function testRedeemCollateralEmitsEvent() public depositedCollateral {
        vm.startPrank(user);
        vm.expectEmit(true, true, false, true, address(dscEngine));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        dscEngine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    function testRevertRedeemCollateralBreaksHealthFactor() public depositedCollateralAndMintedDsc {
        // User has 10 ETH ($20,000) collateral and 100 DSC debt
        // Trying to redeem all collateral should fail
        vm.startPrank(user);
        vm.expectRevert(); // DSCEngine__BreaksHealthFactor
        dscEngine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    function testCanRedeemPartialCollateralWithDebt() public depositedCollateralAndMintedDsc {
        // User has 10 ETH ($20,000) and 100 DSC debt
        // Need at least $200 collateral (200% of 100 DSC) = 0.1 ETH
        // Can safely redeem up to 9.9 ETH
        uint256 safeRedeemAmount = 9.9 ether;
        vm.prank(user);
        dscEngine.redeemCollateral(weth, safeRedeemAmount);

        uint256 remaining = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(remaining, amountCollateral - safeRedeemAmount);
    }

    /*//////////////////////////////////////////////////////////////
                    REDEEM COLLATERAL FOR DSC TESTS
    //////////////////////////////////////////////////////////////*/

    function testRedeemCollateralForDscSuccess() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userDscBalance = dsc.balanceOf(user);
        uint256 userCollateral = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(userDscBalance, 0);
        assertEq(userCollateral, 0);
    }

    function testRevertRedeemCollateralForDscZeroCollateral() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testRevertLiquidateHealthyUser() public depositedCollateralAndMintedDsc {
        // User is healthy, should not be liquidatable
        deal(weth, liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    function testRevertLiquidateZeroDebt() public {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.liquidate(weth, user, 0);
    }

    function testLiquidationSuccess() public liquidated {
        // After liquidation, user's debt should be reduced
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    function testLiquidatorReceivesBonusCollateral() public {
        // Setup: user deposits and mints at near-max
        deal(weth, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Crash ETH price to make user liquidatable
        int256 ethUsdUpdatedPrice = 18e8; // $18/ETH -> 10 ETH = $180, debt = 100 DSC
        MockV3Aggregator(wethUSDPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Setup liquidator
        deal(weth, liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);

        // Calculate expected bonus
        // 100 DSC at $18/ETH = 100/18 = ~5.555 ETH + 10% bonus = ~6.111 ETH
        uint256 expectedTokenFromDebt = dscEngine.getTokenAmountFromUsd(weth, amountToMint);
        uint256 expectedBonus = (expectedTokenFromDebt * 10) / 100;
        uint256 expectedTotalCollateral = expectedTokenFromDebt + expectedBonus;

        uint256 liquidatorWethBefore = ERC20Mock(weth).balanceOf(liquidator);
        dscEngine.liquidate(weth, user, amountToMint);
        uint256 liquidatorWethAfter = ERC20Mock(weth).balanceOf(liquidator);
        vm.stopPrank();

        uint256 liquidatorWethGained = liquidatorWethAfter - liquidatorWethBefore;
        assertEq(liquidatorWethGained, expectedTotalCollateral);
    }

    function testLiquidationImprovesHealthFactor() public {
        // Setup user
        deal(weth, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Crash price
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(wethUSDPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 healthFactorBefore = dscEngine.getHealthFactor(user);

        // Liquidator
        deal(weth, liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, user, amountToMint);
        vm.stopPrank();

        uint256 healthFactorAfter = dscEngine.getHealthFactor(user);
        assert(healthFactorAfter > healthFactorBefore);
    }

    /*//////////////////////////////////////////////////////////////
                         HEALTH FACTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testHealthFactorWithNoDebt() public depositedCollateral {
        uint256 healthFactor = dscEngine.getHealthFactor(user);
        assertEq(healthFactor, type(uint256).max);
    }

    function testHealthFactorWithDebt() public depositedCollateralAndMintedDsc {
        // 10 ETH at $2000 = $20,000 collateral
        // 100 DSC debt
        // HF = ($20,000 * 50 / 100) * 1e18 / 100e18 = $10,000 * 1e18 / 100e18 = 100e18
        uint256 expectedHealthFactor = 100e18;
        uint256 actualHealthFactor = dscEngine.getHealthFactor(user);
        assertEq(actualHealthFactor, expectedHealthFactor);
    }

    function testHealthFactorAtMinimum() public {
        // Deposit exactly enough collateral for max mint
        deal(weth, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);
        // Max mint = $10,000 DSC for $20,000 collateral
        uint256 maxMint = 10_000e18;
        dscEngine.mintDsc(maxMint);
        vm.stopPrank();

        uint256 healthFactor = dscEngine.getHealthFactor(user);
        assertEq(healthFactor, 1e18); // Exactly at minimum
    }

    function testCalculateHealthFactorPure() public view {
        uint256 totalDscMinted = 1000e18;
        uint256 collateralValueInUsd = 4000e18;
        // HF = (4000 * 50 / 100) * 1e18 / 1000 = 2e18
        uint256 expectedHf = 2e18;
        uint256 actualHf = dscEngine.calculateHealthFactor(totalDscMinted, collateralValueInUsd);
        assertEq(actualHf, expectedHf);
    }

    function testCalculateHealthFactorZeroDebt() public view {
        uint256 healthFactor = dscEngine.calculateHealthFactor(0, 10_000e18);
        assertEq(healthFactor, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           GETTER TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetCollateralBalanceOfUser() public depositedCollateral {
        uint256 balance = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(balance, amountCollateral);
    }

    function testGetCollateralBalanceOfUserNoDeposit() public view {
        uint256 balance = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(balance, 0);
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 collateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 expectedValue = dscEngine.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedValue);
    }

    function testGetPrecision() public view {
        assertEq(dscEngine.getPrecision(), 1e18);
    }

    function testGetAdditionalFeedPrecision() public view {
        assertEq(dscEngine.getAdditionalFeedPrecision(), 1e10);
    }

    function testGetLiquidationThreshold() public view {
        assertEq(dscEngine.getLiquidationThreshold(), 50);
    }

    function testGetLiquidationBonus() public view {
        assertEq(dscEngine.getLiquidationBonus(), 10);
    }

    function testGetLiquidationPrecision() public view {
        assertEq(dscEngine.getLiquidationPrecision(), 100);
    }

    function testGetMinHealthFactor() public view {
        assertEq(dscEngine.getMinHealthFactor(), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier depositedCollateral() {
        deal(weth, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        deal(weth, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    modifier liquidated() {
        // Setup user position
        deal(weth, user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Crash ETH price
        int256 ethUsdUpdatedPrice = 18e8; // $18/ETH
        MockV3Aggregator(wethUSDPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Setup liquidator and liquidate
        deal(weth, liquidator, collateralToCover);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, user, amountToMint);
        vm.stopPrank();
        _;
    }
}
