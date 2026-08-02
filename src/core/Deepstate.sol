// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@forge-std/interfaces/IERC20.sol";

import {SettlerAbstract} from "../SettlerAbstract.sol";
import {IDeepstateV1} from "../interfaces/IDeepstateV1.sol";
import {tmp} from "../utils/512Math.sol";
import {UnsafeMath} from "../utils/UnsafeMath.sol";
import {SafeTransferLib} from "../vendor/SafeTransferLib.sol";
import {revertConfusedDeputy, InvalidTarget} from "./SettlerErrors.sol";

abstract contract Deepstate is SettlerAbstract {
    using SafeTransferLib for IERC20;
    using UnsafeMath for uint256;

    /// @dev Executes a self-funded Deepstate route using at most `bps` of the current `sellToken` balance.
    /// Every leg is forced to no-rest so a Settler transaction cannot leave behind a maker position.
    function sellToDeepstate(
        IERC20 sellToken,
        uint256 bps,
        IDeepstateV1 deepstate,
        IDeepstateV1.FillParams[] memory fills
    ) internal {
        address target = address(deepstate);
        if (_isRestrictedTarget(target) || target == address(this) || address(sellToken) == target) {
            revertConfusedDeputy();
        }
        if (target.code.length == 0) revert InvalidTarget();

        for (uint256 i; i < fills.length;) {
            fills[i].noRest = true;

            unchecked {
                ++i;
            }
        }

        if (sellToken == ETH_ADDRESS) {
            uint256 value;
            unchecked {
                // Match Settler's existing bps semantics: unreasonable bps is caller-supplied GIGO.
                value = address(this).balance * bps / BASIS;
            }
            deepstate.fillRoute{value: value}(fills);
        } else {
            uint256 sellAmount = tmp().omul(sellToken.fastBalanceOf(address(this)), bps).unsafeDiv(BASIS);

            // Exact, temporary authority caps even adversarial route calldata to the selected balance share.
            sellToken.safeApprove(target, 0);
            sellToken.safeApprove(target, sellAmount);
            deepstate.fillRoute(fills);
            sellToken.safeApprove(target, 0);
        }
    }
}
