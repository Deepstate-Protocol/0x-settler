// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@forge-std/interfaces/IERC20.sol";
import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

import {Deepstate} from "src/core/Deepstate.sol";
import {Permit2PaymentTakerSubmitted} from "src/core/Permit2Payment.sol";
import {Permit2PaymentAbstract} from "src/core/Permit2PaymentAbstract.sol";
import {IDeepstateV1} from "src/interfaces/IDeepstateV1.sol";
import {uint512} from "src/utils/512Math.sol";

import {Utils} from "../Utils.sol";

contract DeepstateTestERC20 is ERC20 {
    constructor() ERC20("Deepstate test token", "DST", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeepstatePoolMock is IDeepstateV1 {
    bool public allNoRest;
    bool public lastFillOrKill;
    uint256 public receivedValue;

    function fillRoute(FillParams[] calldata fills) external payable {
        allNoRest = true;
        receivedValue = msg.value;

        for (uint256 i; i < fills.length;) {
            FillParams calldata fill = fills[i];
            allNoRest = allNoRest && fill.noRest;
            lastFillOrKill = fill.fillOrKill;

            address inputToken = fill.isBid ? fill.token1 : fill.token0;
            if (inputToken != address(0)) IERC20(inputToken).transferFrom(msg.sender, address(this), 1);

            unchecked {
                ++i;
            }
        }
    }
}

contract DeepstateDummy is Permit2PaymentTakerSubmitted, Deepstate {
    function sell(IDeepstateV1 deepstate, IDeepstateV1.FillParams[] memory fills) external payable {
        sellToDeepstate(deepstate, fills);
    }

    function _tokenId() internal pure override returns (uint256) {
        revert("unimplemented");
    }

    function _hasMetaTxn() internal pure override returns (bool) {
        return false;
    }

    function _div512to256(uint512, uint512) internal view override returns (uint256) {
        revert("unimplemented");
    }

    function _isRestrictedTarget(address target)
        internal
        view
        override(Permit2PaymentTakerSubmitted, Permit2PaymentAbstract)
        returns (bool)
    {
        return super._isRestrictedTarget(target);
    }
}

contract DeepstateUnitTest is Utils, Test {
    DeepstateDummy private settler;
    DeepstatePoolMock private deepstate;
    DeepstateTestERC20 private token0;
    DeepstateTestERC20 private token1;

    address private permit2 = _etchNamedRejectionDummy("PERMIT2", 0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function setUp() public {
        settler = new DeepstateDummy();
        deepstate = new DeepstatePoolMock();
        token0 = new DeepstateTestERC20();
        token1 = new DeepstateTestERC20();
    }

    function testDeepstateForcesNoRestAndApprovesInput() public {
        token1.mint(address(settler), 1);

        IDeepstateV1.FillParams[] memory fills = new IDeepstateV1.FillParams[](1);
        fills[0] = IDeepstateV1.FillParams({
            token0: address(token0),
            token1: address(token1),
            epoch: 0,
            order: bytes32(0),
            isBid: true,
            noRest: false,
            fillOrKill: true
        });

        settler.sell(deepstate, fills);

        assertTrue(deepstate.allNoRest());
        assertTrue(deepstate.lastFillOrKill());
        assertEq(token1.balanceOf(address(deepstate)), 1);
        assertEq(token1.allowance(address(settler), address(deepstate)), type(uint256).max);
        assertEq(token0.allowance(address(settler), address(deepstate)), 0);
    }

    function testDeepstateForwardsNativeBalanceOnlyForNativeInput() public {
        IDeepstateV1.FillParams[] memory fills = new IDeepstateV1.FillParams[](1);
        fills[0] = IDeepstateV1.FillParams({
            token0: address(0),
            token1: address(token1),
            epoch: 0,
            order: bytes32(0),
            isBid: false,
            noRest: false,
            fillOrKill: false
        });

        vm.deal(address(settler), 1 ether);
        settler.sell(deepstate, fills);

        assertTrue(deepstate.allNoRest());
        assertEq(deepstate.receivedValue(), 1 ether);
    }

    function testDeepstateRejectsRestrictedTarget() public {
        IDeepstateV1.FillParams[] memory fills = new IDeepstateV1.FillParams[](0);

        vm.expectRevert();
        settler.sell(IDeepstateV1(permit2), fills);
    }
}
