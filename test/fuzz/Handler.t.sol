// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../test/mocks/MockV3Aggregator.sol";

contract HandlerTests is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator wethPriceFeed;
    MockV3Aggregator wbtcPriceFeed;

    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public constant MIN_DEPOSIT_SIZE = 1;

    // Ghost variables for tracking protocol state across calls
    uint256 public timesMintIsCalled;
    uint256 public timesDepositIsCalled;
    uint256 public timesRedeemIsCalled;
    address[] public usersWithCollateral;
    mapping(address => bool) private hasCollateral;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _dscEngine) {
        dsc = _dsc;
        dscEngine = _dscEngine;
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        wethPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
        wbtcPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(wbtc)));
    }

    /*//////////////////////////////////////////////////////////////
                         DEPOSIT COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function depositCollateral(uint256 _seed, uint256 _amount) public {
        ERC20Mock token = _getCollateralFromSeed(_seed);
        _amount = bound(_amount, MIN_DEPOSIT_SIZE, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        token.mint(msg.sender, _amount);
        token.approve(address(dscEngine), _amount);
        dscEngine.depositCollateral(address(token), _amount);
        vm.stopPrank();

        // Track users who have deposited
        if (!hasCollateral[msg.sender]) {
            usersWithCollateral.push(msg.sender);
            hasCollateral[msg.sender] = true;
        }
        timesDepositIsCalled++;
    }

    /*//////////////////////////////////////////////////////////////
                              MINT DSC
    //////////////////////////////////////////////////////////////*/

    function mintDsc(uint256 _amount, uint256 _userSeed) public {
        if (usersWithCollateral.length == 0) return;

        // Pick a user who actually has collateral
        address sender = usersWithCollateral[_userSeed % usersWithCollateral.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(sender);
        // Max mintable = (collateralValue * 50 / 100) - currentDebt
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint <= 0) return;

        _amount = bound(_amount, 1, uint256(maxDscToMint));

        vm.prank(sender);
        dscEngine.mintDsc(_amount);
        timesMintIsCalled++;
    }

    /*//////////////////////////////////////////////////////////////
                          REDEEM COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function redeemCollateral(uint256 _seed, uint256 _amount) public {
        if (usersWithCollateral.length == 0) return;

        // Pick a user who has collateral
        address sender = usersWithCollateral[_seed % usersWithCollateral.length];
        ERC20Mock token = _getCollateralFromSeed(_seed);

        uint256 maxRedeemable = dscEngine.getCollateralBalanceOfUser(sender, address(token));
        if (maxRedeemable == 0) return;

        // Calculate how much we can safely redeem without breaking health factor
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(sender);
        if (totalDscMinted > 0) {
            // Need to keep enough collateral to maintain health factor >= 1
            // Required collateral in USD = totalDscMinted * 2 (200% ratio)
            uint256 requiredCollateralUsd = totalDscMinted * 2;
            uint256 currentCollateralUsd = dscEngine.getAccountCollateralValue(sender);
            if (currentCollateralUsd <= requiredCollateralUsd) return;

            uint256 excessCollateralUsd = currentCollateralUsd - requiredCollateralUsd;
            uint256 maxRedeemableByHealth = dscEngine.getTokenAmountFromUsd(address(token), excessCollateralUsd);
            maxRedeemable = maxRedeemable < maxRedeemableByHealth ? maxRedeemable : maxRedeemableByHealth;
        }

        if (maxRedeemable == 0) return;
        _amount = bound(_amount, 1, maxRedeemable);

        vm.prank(sender);
        dscEngine.redeemCollateral(address(token), _amount);
        timesRedeemIsCalled++;
    }

    /*//////////////////////////////////////////////////////////////
                              BURN DSC
    //////////////////////////////////////////////////////////////*/

    function burnDsc(uint256 _amount, uint256 _userSeed) public {
        if (usersWithCollateral.length == 0) return;

        address sender = usersWithCollateral[_userSeed % usersWithCollateral.length];
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(sender);
        if (totalDscMinted == 0) return;

        _amount = bound(_amount, 1, totalDscMinted);

        vm.startPrank(sender);
        dsc.approve(address(dscEngine), _amount);
        dscEngine.burnDsc(_amount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        UPDATE COLLATERAL PRICE
    //////////////////////////////////////////////////////////////*/

    // This can break the invariant if price drops too low!
    // Only used in the FailOnRevert handler variant
    // Commenting out here since fail_on_revert=true in the main handler
    // function updateCollateralPrice(uint96 _newPrice, uint256 _seed) public {
    //     int256 intNewPrice = int256(uint256(_newPrice));
    //     if (intNewPrice <= 0) return;
    //     ERC20Mock token = _getCollateralFromSeed(_seed);
    //     if (address(token) == address(weth)) {
    //         wethPriceFeed.updateAnswer(intNewPrice);
    //     } else {
    //         wbtcPriceFeed.updateAnswer(intNewPrice);
    //     }
    // }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getCollateralFromSeed(uint256 seed) private view returns (ERC20Mock) {
        if (seed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function getUsersWithCollateralCount() external view returns (uint256) {
        return usersWithCollateral.length;
    }
}
