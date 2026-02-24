// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;
    address owner = makeAddr("owner");
    address user = makeAddr("user");

    function setUp() public {
        vm.prank(owner);
        dsc = new DecentralizedStableCoin(owner);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testNameAndSymbol() public view {
        assertEq(dsc.name(), "DecentralizedStableCoin");
        assertEq(dsc.symbol(), "DSC");
    }

    function testOwnerIsSetCorrectly() public view {
        assertEq(dsc.owner(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                              MINT TESTS
    //////////////////////////////////////////////////////////////*/

    function testMintSuccess() public {
        vm.prank(owner);
        bool success = dsc.mint(user, 100e18);
        assertTrue(success);
        assertEq(dsc.balanceOf(user), 100e18);
    }

    function testRevertMintNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        dsc.mint(user, 100e18);
    }

    function testRevertMintToZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NotZeroAddress.selector);
        dsc.mint(address(0), 100e18);
    }

    function testRevertMintZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__AmountMustBeMoreThanZero.selector);
        dsc.mint(user, 0);
    }

    function testMintIncreasesTotalSupply() public {
        vm.prank(owner);
        dsc.mint(user, 100e18);
        assertEq(dsc.totalSupply(), 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                              BURN TESTS
    //////////////////////////////////////////////////////////////*/

    function testBurnSuccess() public {
        vm.startPrank(owner);
        dsc.mint(owner, 100e18);
        dsc.burn(50e18);
        vm.stopPrank();

        assertEq(dsc.balanceOf(owner), 50e18);
    }

    function testRevertBurnNotOwner() public {
        vm.prank(owner);
        dsc.mint(user, 100e18);

        vm.prank(user);
        vm.expectRevert();
        dsc.burn(50e18);
    }

    function testRevertBurnZeroAmount() public {
        vm.startPrank(owner);
        dsc.mint(owner, 100e18);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__AmountMustBeMoreThanZero.selector);
        dsc.burn(0);
        vm.stopPrank();
    }

    function testRevertBurnAmountExceedsBalance() public {
        vm.startPrank(owner);
        dsc.mint(owner, 100e18);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(101e18);
        vm.stopPrank();
    }

    function testBurnReducesTotalSupply() public {
        vm.startPrank(owner);
        dsc.mint(owner, 100e18);
        dsc.burn(40e18);
        vm.stopPrank();

        assertEq(dsc.totalSupply(), 60e18);
    }

    /*//////////////////////////////////////////////////////////////
                           TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function testTransferWorks() public {
        vm.prank(owner);
        dsc.mint(user, 100e18);

        address recipient = makeAddr("recipient");
        vm.prank(user);
        dsc.transfer(recipient, 50e18);

        assertEq(dsc.balanceOf(user), 50e18);
        assertEq(dsc.balanceOf(recipient), 50e18);
    }

    function testApproveAndTransferFrom() public {
        vm.prank(owner);
        dsc.mint(user, 100e18);

        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");

        vm.prank(user);
        dsc.approve(spender, 50e18);

        vm.prank(spender);
        dsc.transferFrom(user, recipient, 50e18);

        assertEq(dsc.balanceOf(recipient), 50e18);
    }
}
