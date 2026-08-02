// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@forge-std/interfaces/IERC20.sol";
import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

import {ISettlerActions} from "src/ISettlerActions.sol";
import {BaseSettler} from "src/chains/Base/TakerSubmitted.sol";
import {Permit2PaymentTakerSubmitted} from "src/core/Permit2Payment.sol";
import {Permit2PaymentAbstract} from "src/core/Permit2PaymentAbstract.sol";
import {Deepstate} from "src/core/Deepstate.sol";
import {ConfusedDeputy, InvalidTarget} from "src/core/SettlerErrors.sol";
import {ISettlerBase} from "src/interfaces/ISettlerBase.sol";
import {IDeepstateV1} from "src/interfaces/IDeepstateV1.sol";
import {uint512} from "src/utils/512Math.sol";

import {Utils} from "../Utils.sol";

contract DeepstateTestERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_, 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeepstatePoolMock is IDeepstateV1 {
    error FillFailed();

    IERC20 public inputToken;
    IERC20 public outputToken;
    IERC20 public unrelatedToken;
    uint256 public inputAmount;
    uint256 public outputAmount;
    uint256 public observedInputAllowance;
    uint256 public observedUnrelatedAllowance;
    uint256 public receivedValue;
    uint256 public callCount;
    bool public allNoRest;
    bool public lastFillOrKill;
    bool public shouldRevert;

    function configure(IERC20 inputToken_, IERC20 outputToken_, uint256 inputAmount_, uint256 outputAmount_) external {
        inputToken = inputToken_;
        outputToken = outputToken_;
        inputAmount = inputAmount_;
        outputAmount = outputAmount_;
    }

    function observeUnrelatedToken(IERC20 token) external {
        unrelatedToken = token;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function fillRoute(FillParams[] calldata fills) external payable {
        if (shouldRevert) revert FillFailed();

        ++callCount;
        receivedValue = msg.value;
        allNoRest = true;

        for (uint256 i; i < fills.length;) {
            allNoRest = allNoRest && fills[i].noRest;
            lastFillOrKill = fills[i].fillOrKill;
            unchecked {
                ++i;
            }
        }

        if (address(inputToken) != address(0)) {
            observedInputAllowance = inputToken.allowance(msg.sender, address(this));
            if (address(unrelatedToken) != address(0)) {
                observedUnrelatedAllowance = unrelatedToken.allowance(msg.sender, address(this));
            }
            if (inputAmount != 0) inputToken.transferFrom(msg.sender, address(this), inputAmount);
        }

        if (outputAmount != 0) {
            if (address(outputToken) == address(0)) {
                (bool success,) = payable(msg.sender).call{value: outputAmount}("");
                require(success);
            } else {
                outputToken.transfer(msg.sender, outputAmount);
            }
        }
    }

    receive() external payable {}
}

contract DeepstateDummy is Permit2PaymentTakerSubmitted, Deepstate {
    function sell(IERC20 sellToken, uint256 bps, IDeepstateV1 deepstate, IDeepstateV1.FillParams[] memory fills)
        external
        payable
    {
        sellToDeepstate(sellToken, bps, deepstate, fills);
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
    IERC20 private constant ETH_ADDRESS = IERC20(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    uint256 private constant BASIS = 10_000;

    DeepstateDummy private settler;
    DeepstatePoolMock private deepstate;
    DeepstateTestERC20 private sellToken;
    DeepstateTestERC20 private buyToken;
    DeepstateTestERC20 private unrelatedToken;

    address private permit2 = _etchNamedRejectionDummy("PERMIT2", 0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function setUp() public {
        settler = new DeepstateDummy();
        deepstate = new DeepstatePoolMock();
        sellToken = new DeepstateTestERC20("Sell token", "SELL");
        buyToken = new DeepstateTestERC20("Buy token", "BUY");
        unrelatedToken = new DeepstateTestERC20("Unrelated token", "OTHER");
    }

    function testDeepstateBoundsERC20SpendAndClearsAllowance() public {
        sellToken.mint(address(settler), 100);
        buyToken.mint(address(deepstate), 25);
        deepstate.configure(IERC20(address(sellToken)), IERC20(address(buyToken)), 60, 25);
        deepstate.observeUnrelatedToken(IERC20(address(unrelatedToken)));

        IDeepstateV1.FillParams[] memory fills = _fills();
        fills[0].fillOrKill = true;
        settler.sell(IERC20(address(sellToken)), 6_000, deepstate, fills);

        assertTrue(deepstate.allNoRest());
        assertTrue(deepstate.lastFillOrKill());
        assertEq(deepstate.observedInputAllowance(), 60);
        assertEq(deepstate.observedUnrelatedAllowance(), 0);
        assertEq(sellToken.balanceOf(address(settler)), 40);
        assertEq(sellToken.balanceOf(address(deepstate)), 60);
        assertEq(buyToken.balanceOf(address(settler)), 25);
        assertEq(sellToken.allowance(address(settler), address(deepstate)), 0);
        assertEq(unrelatedToken.allowance(address(settler), address(deepstate)), 0);
    }

    function testFuzzDeepstateERC20BpsBound(uint128 balance, uint16 rawBps) public {
        uint256 bps = bound(rawBps, 0, BASIS);
        uint256 expectedSellAmount = uint256(balance) * bps / BASIS;
        sellToken.mint(address(settler), balance);
        deepstate.configure(IERC20(address(sellToken)), IERC20(address(0)), expectedSellAmount, 0);

        settler.sell(IERC20(address(sellToken)), bps, deepstate, _fills());

        assertEq(deepstate.observedInputAllowance(), expectedSellAmount);
        assertEq(sellToken.balanceOf(address(deepstate)), expectedSellAmount);
        assertEq(sellToken.balanceOf(address(settler)), uint256(balance) - expectedSellAmount);
        assertEq(sellToken.allowance(address(settler), address(deepstate)), 0);
    }

    function testDeepstateExactAllowancePreventsOverpull() public {
        sellToken.mint(address(settler), 100);
        deepstate.configure(IERC20(address(sellToken)), IERC20(address(0)), 61, 0);

        vm.expectRevert();
        settler.sell(IERC20(address(sellToken)), 6_000, deepstate, _fills());

        assertEq(sellToken.balanceOf(address(settler)), 100);
        assertEq(sellToken.balanceOf(address(deepstate)), 0);
        assertEq(sellToken.allowance(address(settler), address(deepstate)), 0);
        assertEq(deepstate.callCount(), 0);
    }

    function testDeepstateHandlesMaximumERC20BalanceWithoutOverflow() public {
        sellToken.mint(address(settler), type(uint256).max);
        deepstate.configure(IERC20(address(sellToken)), IERC20(address(0)), type(uint256).max, 0);

        settler.sell(IERC20(address(sellToken)), BASIS, deepstate, _fills());

        assertEq(deepstate.observedInputAllowance(), type(uint256).max);
        assertEq(sellToken.balanceOf(address(settler)), 0);
        assertEq(sellToken.balanceOf(address(deepstate)), type(uint256).max);
        assertEq(sellToken.allowance(address(settler), address(deepstate)), 0);
    }

    function testDeepstateForwardsOnlySelectedNativeBalance() public {
        vm.deal(address(settler), 10 ether);
        deepstate.configure(IERC20(address(0)), IERC20(address(0)), 0, 0);

        settler.sell(ETH_ADDRESS, 6_000, deepstate, _fills());

        assertTrue(deepstate.allNoRest());
        assertEq(deepstate.receivedValue(), 6 ether);
        assertEq(address(settler).balance, 4 ether);
        assertEq(address(deepstate).balance, 6 ether);
    }

    function testERC20RouteDoesNotForwardUnrelatedNativeBalance() public {
        vm.deal(address(settler), 10 ether);
        sellToken.mint(address(settler), 100);
        deepstate.configure(IERC20(address(sellToken)), IERC20(address(0)), 100, 0);

        settler.sell(IERC20(address(sellToken)), BASIS, deepstate, _fills());

        assertEq(deepstate.receivedValue(), 0);
        assertEq(address(settler).balance, 10 ether);
        assertEq(address(deepstate).balance, 0);
    }

    function testDeepstateRevertIsAtomic() public {
        sellToken.mint(address(settler), 100);
        deepstate.configure(IERC20(address(sellToken)), IERC20(address(0)), 60, 0);
        deepstate.setShouldRevert(true);

        vm.expectRevert(DeepstatePoolMock.FillFailed.selector);
        settler.sell(IERC20(address(sellToken)), 6_000, deepstate, _fills());

        assertEq(sellToken.balanceOf(address(settler)), 100);
        assertEq(sellToken.balanceOf(address(deepstate)), 0);
        assertEq(sellToken.allowance(address(settler), address(deepstate)), 0);
    }

    function testDeepstateRejectsRestrictedAndConfusedTargets() public {
        vm.expectRevert(ConfusedDeputy.selector);
        settler.sell(ETH_ADDRESS, BASIS, IDeepstateV1(permit2), _fills());

        vm.expectRevert(ConfusedDeputy.selector);
        settler.sell(IERC20(address(deepstate)), BASIS, deepstate, _fills());

        vm.expectRevert(ConfusedDeputy.selector);
        settler.sell(ETH_ADDRESS, BASIS, IDeepstateV1(address(settler)), _fills());
    }

    function testDeepstateRejectsTargetWithoutCode() public {
        vm.expectRevert(InvalidTarget.selector);
        settler.sell(ETH_ADDRESS, BASIS, IDeepstateV1(address(0xBEEF)), _fills());
    }

    function testDeepstateActionEncodingUsesPublicABI() public pure {
        IDeepstateV1.FillParams[] memory fills = new IDeepstateV1.FillParams[](0);
        bytes memory action =
            abi.encodeCall(ISettlerActions.DEEPSTATE, (address(ETH_ADDRESS), BASIS, IDeepstateV1(address(1)), fills));

        assertEq(bytes4(action), ISettlerActions.DEEPSTATE.selector);
    }

    function testDeepstateActionDispatchesThroughSettler() public {
        BaseSettler deployedSettler = new BaseSettler(bytes20(0));
        sellToken.mint(address(deployedSettler), 100);
        buyToken.mint(address(deepstate), 25);
        deepstate.configure(IERC20(address(sellToken)), IERC20(address(buyToken)), 60, 25);

        bytes[] memory actions = new bytes[](1);
        actions[0] = abi.encodeCall(ISettlerActions.DEEPSTATE, (address(sellToken), 6_000, deepstate, _fills()));

        deployedSettler.execute(
            ISettlerBase.AllowedSlippage({
                recipient: payable(address(this)), buyToken: IERC20(address(buyToken)), minAmountOut: 25
            }),
            actions,
            bytes32(0)
        );

        assertTrue(deepstate.allNoRest());
        assertEq(sellToken.balanceOf(address(deployedSettler)), 40);
        assertEq(sellToken.balanceOf(address(deepstate)), 60);
        assertEq(buyToken.balanceOf(address(this)), 25);
        assertEq(sellToken.allowance(address(deployedSettler), address(deepstate)), 0);
    }

    function _fills() private view returns (IDeepstateV1.FillParams[] memory fills) {
        fills = new IDeepstateV1.FillParams[](1);
        fills[0] = IDeepstateV1.FillParams({
            token0: address(buyToken),
            token1: address(sellToken),
            epoch: 0,
            order: bytes32(0),
            isBid: true,
            noRest: false,
            fillOrKill: false
        });
    }
}
