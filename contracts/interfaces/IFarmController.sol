// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;
interface IFarmController {
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 workingSupply; // boosted user share.
        uint256 rewardPerShare; // Accumulated reward per share.
        uint256 pendingReward; // reward not claimed
        uint256[] tokenIds; // staked token IDs
    }

    // Info of each pool.
    struct PoolInfo {
        address token0; // Address of token0 contract.
        address token1; // Address of token1 contract.
        uint24 fee; // fee tier of the pool
        uint256 allocPoint; // How many allocation points assigned to this pool. CAKEs to distribute per block.
        uint256 lastRewardTime; // Last block number that CAKEs distribution occurs.
        uint256 totalSupply; // token total supply.
        uint256 workingSupply; // boosted token supply.
        uint256 accRewardPerShare; // Accumulated reward per share.
    }

    // Info of each pool by token id
    struct PoolInfoByTokenId {
        bool active;    //true if the token id is deposited into address(this)
        address token0; // Address of token0 contract.
        address token1; // Address of token1 contract.
        uint24 fee; // fee tier of the pool
        address owner; // owner of NFT
    }

    function userUsedTokenIds(address user, uint256 pid) external view returns (uint256[] memory tokenIds);
    function getPoolInfoByTokenId(uint256 tokenId) external view returns (PoolInfoByTokenId memory poolInfoEntry);
    function nonBoostFactor() external view returns(uint);
    function boostTotalSupply() external view returns(uint);
    function boostBalance(address _user) external view returns(uint);
    function getAllocPointByPid(uint256 pid) external view returns (uint256 allocPoint);
    function totalAllocPoint() external view returns (uint);
    function poolInfo(uint256 pid) external view returns (PoolInfo memory);
}