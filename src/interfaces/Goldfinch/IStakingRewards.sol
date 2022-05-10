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

    /// @notice Unstake an amount of `stakingToken()` associated with a given position and transfer to msg.sender.
    ///   Unvested rewards will be forfeited, but remaining staked amount will continue to accrue rewards.
    ///   Positions that are still locked cannot be unstaked until the position's lockedUntil time has passed.
    /// @dev This function checkpoints rewards
    /// @param tokenId A staking position token ID
    /// @param amount Amount of `stakingToken()` to be unstaked from the position
    function unstake(uint256 tokenId, uint256 amount) external;

    /// @notice Claim rewards for a given staked position
    /// @param tokenId A staking position token ID
    function getReward(uint256 tokenId) external;

      /// @notice Returns the rewards claimable by a given position token at the most recent checkpoint, taking into
      /// account vesting schedule.
      /// @return rewards Amount of rewards denominated in `rewardsToken()`
    function claimableRewards(uint256 tokenId)  external;
}