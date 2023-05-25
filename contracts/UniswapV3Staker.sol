// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IUniswapV3Staker.sol';
import './libraries/IncentiveId.sol';
import './libraries/NFTPositionInfo.sol';
import './libraries/TransferHelperExtended.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';

import '@uniswap/v3-core/contracts/libraries/FullMath.sol';
import '@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol';
import "./roles/WhitelistedRole.sol";
import "./utils/NeedInitialize.sol";
import "./interfaces/VotingEscrow.sol";
/// @title Uniswap V3 canonical staking interface
contract UniswapV3Staker is IUniswapV3Staker, Multicall, NeedInitialize, WhitelistedRole {
    using LowGasSafeMath for uint256;
    // Info of each pool.
    struct PoolInfo {
        address pool; // pool address
        uint256 allocPoint; // How many allocation points assigned to this pool. CAKEs to distribute per block.
    }
    // Stats of each pool.
    struct PoolStat {
        uint128 totalSupply; // token total supply.
        uint128 workingSupply; // boosted token supply.
    }
    /// @notice Represents a staking incentive
    struct Incentive {
        uint160 totalSecondsClaimedX128;
        uint96 numberOfStakes;
        uint256 totalRewardClaimed;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint160 secondsPerLiquidityInsideInitialX128;
        uint96 liquidityNoOverflow;
        uint128 liquidityIfOverflow;
        uint128 workingSupply; 
    }

    /// @inheritdoc IUniswapV3Staker
    IUniswapV3Factory public override factory;
    /// @inheritdoc IUniswapV3Staker
    INonfungiblePositionManager public override nonfungiblePositionManager;

    /// @inheritdoc IUniswapV3Staker
    uint256 public override maxIncentiveStartLeadTime;
    /// @inheritdoc IUniswapV3Staker
    uint256 public override maxIncentiveDuration;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev stakes[tokenId][incentiveHash] => Stake
    mapping(uint256 => mapping(bytes32 => Stake)) private _stakes;

    IVotingEscrow public votingEscrow;
    uint256 public k1;
    uint256 public k2;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // bytes32: incentiveId
    mapping(bytes32 => PoolStat) public poolStat;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;
    /// @dev address: msg.sender, bytes32: incentiveId userRewardProduced
    mapping(address =>  mapping(bytes32 => uint256)) public userRewardProduced;
    /// @dev bytes32 refers to the return value of IncentiveId.computeIgnoringPool
    mapping(bytes32 => uint256) public totalRewardUnclaimed;

    mapping(address => uint256[]) public tokenIds;

    uint256 public unclaimableEndtime;

    /// @inheritdoc IUniswapV3Staker
    function stakes(uint256 tokenId, bytes32 incentiveId)
        public
        view
        override
        returns (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity)
    {
        Stake storage stake = _stakes[tokenId][incentiveId];
        secondsPerLiquidityInsideInitialX128 = stake.secondsPerLiquidityInsideInitialX128;
        liquidity = stake.liquidityNoOverflow;
        if (liquidity == type(uint96).max) {
            liquidity = stake.liquidityIfOverflow;
        }
    }

    /// @dev rewards[owner] => uint256
    /// @inheritdoc IUniswapV3Staker
    mapping(address => uint256) public override rewards;

    /// @param _factory the Uniswap V3 factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentiveDuration the max amount of seconds into the future the incentive startTime can be set
    function initialize(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration,
        address _votingEscrow,
        uint256 _k1,
        uint256 _k2,
        uint256 _unclaimableEndtime
    ) external onlyInitializeOnce {
        _addWhitelistAdmin(msg.sender);
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentiveDuration = _maxIncentiveDuration;
        votingEscrow = IVotingEscrow(_votingEscrow);
        k1 = _k1;
        k2 = _k2;
        unclaimableEndtime = _unclaimableEndtime;
    }
    // Add a new lp to the pool. Can only be called by the whitelist admin.
    function add(
        uint256 _allocPoint,
        address _pool
    ) external onlyWhitelistAdmin {
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolInfo.push(
            PoolInfo({
                pool: _pool,
                allocPoint: _allocPoint
            })
        );
    }
    // Update the given pool's reward allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint
    ) external onlyWhitelistAdmin {
        require(_pid < poolInfo.length, "UniswapV3Staker::set: pid not exist");
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }
    /// @inheritdoc IUniswapV3Staker
    function createIncentive(IncentiveKey memory key, uint256 reward) external override onlyWhitelistAdmin{
        require(reward > 0, 'UniswapV3Staker::createIncentive: reward must be positive');
        require(
            block.timestamp <= key.startTime,
            'UniswapV3Staker: start time must be now or in the future'
        );
        require(
            key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
            'UniswapV3Staker: start time too far into future'
        );
        require(key.startTime < key.endTime, 'UniswapV3Staker: start time must be before end time');
        require(
            key.endTime - key.startTime <= maxIncentiveDuration,
            'UniswapV3Staker: incentive duration is too long'
        );
        require(
            key.endTime > unclaimableEndtime,
            'UniswapV3Staker: endTime must be longer than unclaimable end time'
        );

        totalRewardUnclaimed[IncentiveId.computeIgnoringPool(key)] = totalRewardUnclaimed[IncentiveId.computeIgnoringPool(key)].add(reward);

        TransferHelperExtended.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward);

        emit IncentiveCreated(key.rewardToken, key.pool, key.startTime, key.endTime, key.refundee, reward);
    }

    /// @notice Upon receiving a Uniswap V3 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }
    function depositToken(uint256 tokenId) external {
        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager.positions(tokenId);

        deposits[tokenId] = Deposit({owner: msg.sender, numberOfStakes: 0, tickLower: tickLower, tickUpper: tickUpper});
        tokenIds[msg.sender].push(tokenId);
        emit DepositTransferred(tokenId, address(0), msg.sender);
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId);
    }
    function tokenIdsLength(address owner) external view returns (uint256) {
        return tokenIds[owner].length;
    }
    /// @inheritdoc IUniswapV3Staker
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(0), 'UniswapV3Staker::transferDeposit: invalid transfer recipient');
        address owner = deposits[tokenId].owner;
        require(owner == msg.sender, 'UniswapV3Staker::transferDeposit: can only be called by deposit owner');
        deposits[tokenId].owner = to;
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IUniswapV3Staker
    function withdrawToken(
        uint256 tokenId,
        address to
    ) external override {
        require(to != address(this), 'UniswapV3Staker::withdrawToken: cannot withdraw to staker');
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'UniswapV3Staker::withdrawToken: cannot withdraw token while staked');
        require(deposit.owner == msg.sender, 'UniswapV3Staker::withdrawToken: only owner can withdraw token');

        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId);
    }

    /// @inheritdoc IUniswapV3Staker
    function stakeToken(IncentiveKey memory key, uint256 tokenId, uint256 pid) external override {
        require(deposits[tokenId].owner == msg.sender, 'UniswapV3Staker::stakeToken: only owner can stake token');

        _stakeToken(key, tokenId,pid);
    }

    /// @inheritdoc IUniswapV3Staker
    function unstakeToken(IncentiveKey memory key, uint256 tokenId, uint256 pid) external override {
        Deposit memory deposit = deposits[tokenId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        // if (block.timestamp < key.endTime) {
            require(
                deposit.owner == msg.sender && block.timestamp <= key.endTime,
                'UniswapV3Staker::unstakeToken: only owner can withdraw token before incentive end time'
            );
        // }

        bytes32 incentiveId = IncentiveId.compute(key);
        bytes32 incentiveIdIP = IncentiveId.computeIgnoringPool(key);

        (, uint128 liquidity) = stakes(tokenId, incentiveId);

        require(liquidity != 0, 'UniswapV3Staker::unstakeToken: stake does not exist');
        PoolInfo memory poolEntry = poolInfo[pid];
        require(poolEntry.pool == address(key.pool), 'UniswapV3Staker::unstakeToken: pid not match incentive pool');

        Incentive storage incentive = incentives[incentiveId];

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;

        (, uint160 secondsPerLiquidityInsideX128, ) =
            key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);
        rewardParam memory params = rewardParam ( {
            key: key,
            secondsPerLiquidityInsideX128: secondsPerLiquidityInsideX128,
            tokenId: tokenId,
            allocPoint: poolEntry.allocPoint,
            owner: deposit.owner,
            incentiveId: incentiveId,
            incentiveIdIP: incentiveIdIP
        });
        (uint256 reward, uint160 secondsInsideX128, ) =
            computeRewardAmountWithBoosting(
                params
            );
        _checkpoint(incentiveId, tokenId, 0);
        //It cannot underflow since the totalSupply is added by liquidity. Now the liquidity is just removed out of the total supply. So it is safe
        poolStat[incentiveId].totalSupply -= liquidity;
        if (block.timestamp > unclaimableEndtime) {
            // if this overflows, e.g. after 2^32-1 full liquidity seconds have been claimed,
            // reward rate will fall drastically so it's safe
            incentive.totalSecondsClaimedX128 += secondsInsideX128;
            // reward is never greater than total reward unclaimed
            totalRewardUnclaimed[incentiveIdIP] = totalRewardUnclaimed[incentiveIdIP].sub(reward);
            incentive.totalRewardClaimed = incentive.totalRewardClaimed.add(reward);
            // this only overflows if a token has a total supply greater than type(uint256).max
            rewards[deposit.owner] = rewards[deposit.owner].add(reward);
            userRewardProduced[deposit.owner][incentiveId] = userRewardProduced[deposit.owner][incentiveId].add(reward);
        }
        Stake storage stake = _stakes[tokenId][incentiveId];
        delete stake.secondsPerLiquidityInsideInitialX128;
        delete stake.liquidityNoOverflow;
        delete stake.workingSupply;
        if (liquidity >= type(uint96).max) delete stake.liquidityIfOverflow;
        emit TokenUnstaked(tokenId, incentiveId);
    }

    function unstakeTokenAtEnd(IncentiveKey memory key, uint256 tokenId, uint256 pid) external {
        Deposit memory deposit = deposits[tokenId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        // if (block.timestamp < key.endTime) {
            require(
                block.timestamp > key.endTime,
                'UniswapV3Staker::unstakeTokenAtEnd: only unstake after period'
            );
        // }

        bytes32 incentiveId = IncentiveId.compute(key);
        bytes32 incentiveIdIP = IncentiveId.computeIgnoringPool(key);

        (, uint128 liquidity) = stakes(tokenId, incentiveId);

        require(liquidity != 0, 'UniswapV3Staker::unstakeToken: stake does not exist');
        PoolInfo memory poolEntry = poolInfo[pid];
        require(poolEntry.pool == address(key.pool), 'UniswapV3Staker::unstakeToken: pid not match incentive pool');

        Incentive storage incentive = incentives[incentiveId];

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;

        // totalAllocPoint will never be zero when the staker starts to run
        uint256 totalRewardUnclaimedWeighted = totalRewardUnclaimed[incentiveIdIP].mul(poolEntry.allocPoint) / totalAllocPoint;

        Stake storage stake = _stakes[tokenId][incentiveId];
        uint256 reward =  FullMath.mulDiv(totalRewardUnclaimedWeighted, stake.workingSupply, poolStat[incentiveId].workingSupply);

        poolStat[incentiveId].totalSupply -= liquidity;
        // this only overflows if a token has a total supply greater than type(uint256).max
        rewards[deposit.owner] = rewards[deposit.owner].add(reward);
        userRewardProduced[deposit.owner][incentiveId] = userRewardProduced[deposit.owner][incentiveId].add(reward);

        
        delete stake.secondsPerLiquidityInsideInitialX128;
        delete stake.liquidityNoOverflow;
        delete stake.workingSupply;
        if (liquidity >= type(uint96).max) delete stake.liquidityIfOverflow;
        emit TokenUnstaked(tokenId, incentiveId);
    }

    /// @inheritdoc IUniswapV3Staker
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external override returns (uint256 reward) {
        reward = rewards[msg.sender];
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }
        // reward is never be greater than rewards[msg.sender]
        rewards[msg.sender] -= reward;
        TransferHelperExtended.safeTransfer(address(rewardToken), to, reward);

        emit RewardClaimed(to, reward);
    }

    /// @inheritdoc IUniswapV3Staker
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId, uint256 pid)
        external
        view
        override
        returns (uint256 reward, uint160 secondsInsideX128)
    {
        bytes32 incentiveId = IncentiveId.compute(key);
        bytes32 incentiveIdIP = IncentiveId.computeIgnoringPool(key);
        (, uint128 liquidity) = stakes(tokenId, incentiveId);
        require(liquidity > 0, 'UniswapV3Staker::getRewardInfo: stake does not exist');

        Deposit memory deposit = deposits[tokenId];
        // Incentive memory incentive = incentives[incentiveId];

        (, uint160 secondsPerLiquidityInsideX128, ) =
            key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);
        PoolInfo memory poolEntry = poolInfo[pid];
        rewardParam memory params = rewardParam ( {
                    key: key,
                    secondsPerLiquidityInsideX128: secondsPerLiquidityInsideX128,
                    tokenId: tokenId,
                    allocPoint: poolEntry.allocPoint,
                    owner: deposit.owner,
                    incentiveId: incentiveId,
                    incentiveIdIP: incentiveIdIP
                });
        (reward, secondsInsideX128, ) = computeRewardAmountWithBoosting(
            params
        );
        if (block.timestamp > params.key.endTime) {
            uint256 totalRewardUnclaimedWeighted = totalRewardUnclaimed[incentiveIdIP].mul(poolEntry.allocPoint) / totalAllocPoint;
            reward =  FullMath.mulDiv(totalRewardUnclaimedWeighted, _stakes[tokenId][incentiveId].workingSupply, poolStat[incentiveId].workingSupply);
            secondsInsideX128 = 0;
        }
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId, uint256 pid) private {
        require(block.timestamp >= key.startTime, 'UniswapV3Staker::stakeToken: incentive not started');
        require(block.timestamp < key.endTime, 'UniswapV3Staker::stakeToken: incentive ended');

        bytes32 incentiveId = IncentiveId.compute(key);

        require(
            totalRewardUnclaimed[IncentiveId.computeIgnoringPool(key)] > 0,
            'UniswapV3Staker::stakeToken: non-existent incentive'
        );
        require(
            _stakes[tokenId][incentiveId].liquidityNoOverflow == 0,
            'UniswapV3Staker::stakeToken: token already staked'
        );

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            NFTPositionInfo.getPositionInfo(factory, nonfungiblePositionManager, tokenId);
        PoolInfo memory poolEntry = poolInfo[pid];
        require(poolEntry.pool == address(pool), 'UniswapV3Staker::stakeToken: pid not match incentive pool');
        require(pool == key.pool, 'UniswapV3Staker::stakeToken: token pool is not the incentive pool');
        require(liquidity > 0, 'UniswapV3Staker::stakeToken: cannot stake token with 0 liquidity');
        

        poolStat[incentiveId].totalSupply += liquidity;

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(tickLower, tickUpper);
        rewardParam memory params = rewardParam ( {
                    key: key,
                    secondsPerLiquidityInsideX128: secondsPerLiquidityInsideX128,
                    tokenId: tokenId,
                    allocPoint: poolEntry.allocPoint,
                    owner: deposits[tokenId].owner,
                    incentiveId: incentiveId,
                    incentiveIdIP: IncentiveId.computeIgnoringPool(key)
                });
        if (liquidity >= type(uint96).max) {
            _stakes[tokenId][incentiveId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: type(uint96).max,
                liquidityIfOverflow: liquidity,
                workingSupply: 0
            });
        } else {
            Stake storage stake = _stakes[tokenId][incentiveId];
            stake.secondsPerLiquidityInsideInitialX128 = secondsPerLiquidityInsideX128;
            stake.liquidityNoOverflow = uint96(liquidity);
            stake.workingSupply = 0;
        }
        (, , uint256 workingSupply) =
            computeRewardAmountWithBoosting(
                params
            );
        _checkpoint(incentiveId, tokenId, uint128(workingSupply));
        emit TokenStaked(tokenId, incentiveId, liquidity);
    }
    function computeRewardAmountWithBoosting(
        rewardParam memory params
    ) internal view returns (uint256 reward, uint160 secondsInsideX128, uint256 workingSupply) {
        // this should never be called before the start time
        assert(block.timestamp >= params.key.startTime);
        // bytes32 incentiveId = IncentiveId.compute(key);
        // bytes32 incentiveIdIP = IncentiveId.computeIgnoringPool(key);
        Incentive memory incentive = incentives[params.incentiveId];
        uint256 totalRewardUnclaimedWeighted = totalRewardUnclaimed[params.incentiveIdIP].mul(params.allocPoint) / totalAllocPoint;
        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity) = stakes(params.tokenId, params.incentiveId);
        PoolStat memory pool = poolStat[params.incentiveId];
        
        uint256 boostBalance = votingEscrow.balanceOf(params.owner);
        uint256 boostTotalSupply = votingEscrow.totalSupply();
        
        // totalSecondsClaimedX128 is never greater than endTime - startTime
        uint256 totalSecondsUnclaimedX128 =
            ((params.key.endTime - params.key.startTime) << 128) - incentive.totalSecondsClaimedX128;
        // this operation is safe, as the difference cannot be greater than 1/stake.liquidity
        secondsInsideX128 = (params.secondsPerLiquidityInsideX128 - secondsPerLiquidityInsideInitialX128) * liquidity;
        uint256 l = (k1 * secondsInsideX128) / 100;
        if(boostTotalSupply > 0){
            // In this case, boostBalance max is 2^27-1, so 2^160 * 2^ 27 << 2^256 so use * is safe
            l += ((secondsInsideX128*boostBalance) / boostTotalSupply).mul(100 - k1) / 100;
        }
        if (l > secondsInsideX128) {
            l = secondsInsideX128;
        }
        reward = FullMath.mulDiv(totalRewardUnclaimedWeighted, l, totalSecondsUnclaimedX128);
        workingSupply = k1.mul(liquidity) / 100;
        uint256 userRewardProducedEntry = userRewardProduced[params.owner][params.incentiveId];
        if(boostTotalSupply > 0){
            workingSupply = workingSupply.add(_boostFirst(pool.totalSupply, boostBalance, boostTotalSupply));
        }
        if(incentive.totalRewardClaimed > 0){
            // In this case "userRewardProducedEntry + reward", max size of reward is 2^27 - 1 so use + is safe
            workingSupply = workingSupply.add(_boostSecond(pool.totalSupply, (userRewardProducedEntry + reward), incentive.totalRewardClaimed));              
        }
        if (workingSupply > liquidity) {
            workingSupply = liquidity;
        }
    }
    function _boostFirst(
        uint128 _totalSupply,
        uint256 _boostBalance,
        uint256 _boostTotalSupply
    ) internal view returns (uint256 boostResult){
        // In this case, boostBalance max is 2^27-1, so 2^160 * 2^ 27 << 2^256 so use * is safe
        boostResult = ((_totalSupply * _boostBalance) / _boostTotalSupply).mul(100 - k1 - k2) / 100;
    }
    function _boostSecond(
        uint128 _totalSupply,
        uint256 _reward,
        uint256 _totalRewardClaimed
    ) internal view returns (uint256 boostResult){
        // In this case, _reward max is 2^27-1, so 2^128 * 2^ 27 << 2^256 so use * is safe
        boostResult = (_totalSupply * _reward / _totalRewardClaimed).mul(k2) / 100; 
    }
    function _checkpoint(bytes32 _incentiveId, uint256 _tokenId, uint256 l) internal {
        PoolStat storage pool = poolStat[_incentiveId];
        Stake storage user = _stakes[_tokenId][_incentiveId];
        //in vswap-core, the liquidity has a limit to control the overflow. So here workingSupply is never overflow
        pool.workingSupply = pool.workingSupply + uint128(l) - user.workingSupply;
        user.workingSupply = uint128(l);
        emit UpdateWorkingSupply(_tokenId, _incentiveId, l);
    }

    function getPoolStat(IncentiveKey memory key) external view returns (uint128 totalSupply, uint128 workingSupply){
        bytes32 incentiveId = IncentiveId.compute(key);
        totalSupply = poolStat[incentiveId].totalSupply;
        workingSupply = poolStat[incentiveId].workingSupply;
    }

    function getUserWorkingSupply(IncentiveKey memory key, uint256 tokenId) external view returns (uint128 workingSupply){
        bytes32 incentiveId = IncentiveId.compute(key);
        workingSupply = _stakes[tokenId][incentiveId].workingSupply;
    }

}
