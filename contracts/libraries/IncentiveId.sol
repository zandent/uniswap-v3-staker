// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '../interfaces/IUniswapV3Staker.sol';

library IncentiveId {
    /// @notice Calculate the key for a staking incentive
    /// @param key The components used to compute the incentive identifier
    /// @return incentiveId The identifier for the incentive
    function compute(IUniswapV3Staker.IncentiveKey memory key) internal pure returns (bytes32 incentiveId) {
        return keccak256(abi.encode(key));
    }
    function computeIgnoringPool(IUniswapV3Staker.IncentiveKey memory key) internal pure returns (bytes32 incentiveId) {
        IUniswapV3Staker.IncentiveKeyIgnoringPool memory incentiveKeyIgnoringPool = IUniswapV3Staker.IncentiveKeyIgnoringPool({
            rewardToken: key.rewardToken,
            startTime: key.startTime,
            endTime: key.endTime,
            refundee: key.refundee
        });
        return keccak256(abi.encode(incentiveKeyIgnoringPool));
    }
}
