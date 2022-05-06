// SPDX-License-Identifier: MIT

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

interface IStakingRewards {

    /// @notice Stake `stakingToken()` to earn rewards. When you call this function, you'll receive an
    ///   an NFT representing your staked position. You can present your NFT to `getReward` or `unstake`
    ///   to claim rewards or unstake your tokens respectively. Rewards vest over a schedule.
    /// @dev This function checkpoints rewards.
    /// @param amount The amount of `stakingToken()` to stake
    function stake(uint256 amount) external;

    /// @notice Claim rewards for a given staked position
    /// @param tokenId A staking position token ID
    function getReward(uint256 tokenId) external;
}