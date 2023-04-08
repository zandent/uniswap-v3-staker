// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
interface IVotingEscrow {
    function totalSupply() external view returns (uint256 result);
    function balanceOf(address _account) external view returns (uint256);
}
