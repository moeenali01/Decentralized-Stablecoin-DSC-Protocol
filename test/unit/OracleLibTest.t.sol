// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleLib, AggregatorV3Interface} from "../../src/libraries/OracleLib.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract OracleLibTest is Test {
    using OracleLib for AggregatorV3Interface;

    MockV3Aggregator mockPriceFeed;
    uint8 constant DECIMALS = 8;
    int256 constant INITIAL_PRICE = 2000e8;

    function setUp() public {
        mockPriceFeed = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
    }

    function testStaleCheckReturnsCorrectData() public view {
        (, int256 answer,,,) = AggregatorV3Interface(address(mockPriceFeed)).staleCheckLatestRoundData();
        assertEq(answer, INITIAL_PRICE);
    }

    function testRevertsOnStalePrice() public {
        // Warp forward past the 3 hour timeout
        vm.warp(block.timestamp + 3 hours + 1 seconds);
        vm.roll(block.number + 1);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        AggregatorV3Interface(address(mockPriceFeed)).staleCheckLatestRoundData();
    }

    function testStaleCheckPassesAtExactTimeout() public {
        // Warp to exactly 3 hours (should still pass, since check is >)
        vm.warp(block.timestamp + 3 hours);
        vm.roll(block.number + 1);

        (, int256 answer,,,) = AggregatorV3Interface(address(mockPriceFeed)).staleCheckLatestRoundData();
        assertEq(answer, INITIAL_PRICE);
    }

    function testRevertsOnUpdatedAtZero() public {
        // Set updatedAt to 0 via updateRoundData
        mockPriceFeed.updateRoundData(1, INITIAL_PRICE, 0, block.timestamp);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        AggregatorV3Interface(address(mockPriceFeed)).staleCheckLatestRoundData();
    }

    function testGetTimeoutReturnsThreeHours() public view {
        uint256 timeout = OracleLib.getTimeout(AggregatorV3Interface(address(mockPriceFeed)));
        assertEq(timeout, 3 hours);
    }

    function testUpdatedPriceIsReturned() public {
        int256 newPrice = 3000e8;
        mockPriceFeed.updateAnswer(newPrice);

        (, int256 answer,,,) = AggregatorV3Interface(address(mockPriceFeed)).staleCheckLatestRoundData();
        assertEq(answer, newPrice);
    }
}
