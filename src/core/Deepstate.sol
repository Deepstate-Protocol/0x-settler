// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@forge-std/interfaces/IERC20.sol";

import {SettlerAbstract} from "../SettlerAbstract.sol";
import {IDeepstateV1} from "../interfaces/IDeepstateV1.sol";
import {SafeTransferLib} from "../vendor/SafeTransferLib.sol";
import {revertConfusedDeputy} from "./SettlerErrors.sol";

abstract contract Deepstate is SettlerAbstract {
    using SafeTransferLib for IERC20;

    function sellToDeepstate(IDeepstateV1 deepstate, IDeepstateV1.FillParams[] memory fills) internal {
        if (_isRestrictedTarget(address(deepstate))) revertConfusedDeputy();

        bool usesNativeInput;
        for (uint256 i; i < fills.length;) {
            IDeepstateV1.FillParams memory fill = fills[i];
            fill.noRest = true;
            fills[i] = fill;

            address inputToken = fill.isBid ? fill.token1 : fill.token0;
            if (inputToken == address(0)) {
                usesNativeInput = true;
            } else if (inputToken != address(deepstate)) {
                IERC20(inputToken).safeApproveIfBelow(address(deepstate), type(uint256).max);
            }

            unchecked {
                ++i;
            }
        }

        deepstate.fillRoute{value: usesNativeInput ? address(this).balance : 0}(fills);
    }
}
