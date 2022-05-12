// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// Import interfaces for many popular DeFi projects, or add your own!
import "./interfaces/Curve/IStableSwapExchange.sol";
import "./interfaces/Goldfinch/ISeniorPool.sol";
import "./interfaces/Goldfinch/IStakingRewards.sol";
import "./interfaces/ySwap/ITradeFactory.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using Counters for Counters.Counter;
    using EnumerableSet for EnumerableSet.UintSet;

    IStableSwapExchange internal constant curvePool = IStableSwapExchange(0x80aa1a80a30055DAA084E599836532F3e58c95E2);
    ISeniorPool internal constant seniorPool = ISeniorPool(0x8481a6EbAf5c7DABc3F7e09e44A89531fd31F822);
    IStakingRewards internal constant stakingRewards = IStakingRewards(0xFD6FF39DA508d281C2d255e9bBBfAb34B6be60c3);
    IERC20 internal constant FIDU = IERC20(0x6a445E9F40e0b97c92d0b8a3366cEF1d67F700BF);
    IERC20 internal constant GFI = IERC20(0xdab396cCF3d84Cf2D07C4454e10C8A6F5b008D2b);

    // NFT position for staked Fidu
    Counters.Counter tokenIdCounter;
    EnumerableSet.UintSet private _tokenIdList; // Creating a set to store _tokenId'S

    address public tradeFactory = address(0);
    uint256 public maxSlippage; 
    uint256 internal constant MAX_BIPS = 10_000;

    // solhint-disable-next-line no-empty-blocks
    constructor(address _vault) BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        maxSlippage = 30; // Default to 30 bips
        tokenIdCounter = stakingRewards._tokenIdTracker();
    }

    function name() external view override returns (string memory) {
        return "StrategyGoldfinchUSDC";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + ((balanceOfFidu() * seniorPool.sharePrice()) / 1e18) / 1e12; // FIDU -> USDC decimals
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        require(tradeFactory != address(0), "Trade factory must be set.");
        
        // First, claim any rewards.

        _claimRewards();

        // Second, run initial profit + loss calculations.

        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        if (_totalAssets >= _totalDebt) {
            // Implicitly, _profit & _loss are 0 before we change them.
            _profit = _totalAssets - _totalDebt;
        } else {
            _loss = _totalDebt - _totalAssets;
        }

        // Third, free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.

        (uint256 _amountFreed, uint256 _liquidationLoss) =
            liquidatePosition(_debtOutstanding + _profit);

        _loss = _loss + _liquidationLoss;

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }
    }

    // Swap USDC -> FIDU if slippage conditions permit
    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _liquidWant = balanceOfWant();

        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToInvest = _liquidWant - _debtOutstanding;
            _swapWantToFidu(_amountToInvest);
        }

        // stake any unstaked Fidu
        uint256 unstakedBalance = balanceOfFidu();
        if (unstakedBalance > 0) {
            _stakeFidu(unstakedBalance);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        uint256 _fiduToSwap = Math.min((_amountNeeded * 1e30) / seniorPool.sharePrice(), balanceOfFidu()); // 18 decimals for the share price & 12 decimals for USDC -> FIDU 
        _swapFiduToWant(_fiduToSwap, false);

        _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded - _liquidWant;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _swapFiduToWant(balanceOfFidu(), true);
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
            // TODO: Transfer any non-`want` tokens to the new strategy
            // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
        }
        // Override this to add all tokens/tokenized positions this contract manages
        // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
        // NOTE: Do *not* include `want`, already included in `sweep` below
        //
        // Example:
        //
        //    function protectedTokens() internal override view returns (address[] memory) {
        //      address[] memory protected = new address[](3);
        //      protected[0] = tokenA;
        //      protected[1] = tokenB;
        //      protected[2] = tokenC;
        //      return protected;
        //    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {

    }

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }

    // ----------- MANAGEMENT FUNCTIONS -----------

    function swapFiduToWant(uint256 fiduAmount, bool force) external onlyVaultManagers {
        _swapFiduToWant(fiduAmount, force);
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------
    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // approve and set up trade factory
        GFI.safeApprove(_tradeFactory, type(uint256).max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(GFI), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        GFI.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }

    // ------- HELPER AND UTILITY FUNCTIONS -------

    function _swapFiduToWant(uint256 _fiduAmount, bool _force) internal {

        // Loop through _tokenId's and unstake until we get the amount of _fiduAmount required
        uint256 _FiduToUnstake = balanceOfFidu() - _fiduAmount;
        while (balanceOfFidu() > _fiduAmount){
            for (uint256 i=0; i<_tokenIdList.length(); i++) {
                uint256 x = _tokenIdList.at(i);
                if (stakingRewards.stakedBalanceOf(x) <= _FiduToUnstake) {
                    stakingRewards.unstake(x, _FiduToUnstake);
                    _tokenIdList.remove(x); // remove tokenId from the list
                } else { // partial unstake
                    stakingRewards.unstake(x, _FiduToUnstake); }
            _FiduToUnstake = balanceOfFidu() - _fiduAmount; // is there a better way to update the remaining amount to unstake?
            }    
        }

        uint256 _fiduValueInWant = (_fiduAmount * seniorPool.sharePrice()) / 1e30;
        uint256 _expectedOut = curvePool.get_dy(0, 1, _fiduAmount);
        uint256 _allowedSlippageLoss = (_fiduValueInWant * maxSlippage) / MAX_BIPS;

        if (!_force && _fiduValueInWant - _allowedSlippageLoss > _expectedOut) { 
            return; // Too much slippage
        }

        _checkAllowance(address(curvePool), address(FIDU), _fiduAmount);
         
        curvePool.exchange_underlying(0, 1, _fiduAmount, _expectedOut);
    }

    function _swapWantToFidu(uint256 _amount) internal {
        uint256 _expectedOut = curvePool.get_dy(1, 0, _amount);
        uint256 _expectedValueOut = ((_expectedOut * seniorPool.sharePrice()) / 1e18) / 1e12;
        uint256 _allowedSlippageLoss = (_amount * maxSlippage) / MAX_BIPS;

        if (_amount - _allowedSlippageLoss > _expectedValueOut) { 
            return; // Too much slippage
        }

        _checkAllowance(address(curvePool), address(want), _amount); 

        curvePool.exchange_underlying(1, 0, _amount, _expectedOut); 
    }

    function _stakeFidu(uint256 _amountToStake) internal {
        stakingRewards.stake(_amountToStake);
        uint256 _tokenId = tokenIdCounter.current(); // Hack: they don't return the token ID from the stake function, so we need to calculate it
        _tokenIdList.add(_tokenId); // each time we stake Fidu, a new _tokenId is created
    }

    function _unstakeAllFidu() internal {
        for (uint i=0; i<_tokenIdList.length(); i++) {
            uint256 _amountToUnstake = stakingRewards.stakedBalanceOf(i);
            stakingRewards.unstake(i, _amountToUnstake);
            }
    }

    function _claimRewards() internal {
        for (uint i=0; i<_tokenIdList.length(); i++) { // check claimable GFI for each tokenId
            if (stakingRewards.claimableRewards(i) != 0) { 
                stakingRewards.getReward(i); // claim GFI
            }
        }
    }

    // _checkAllowance adapted from https://github.com/therealmonoloco/liquity-stability-pool-strategy/blob/1fb0b00d24e0f5621f1e57def98c26900d551089/contracts/Strategy.sol#L316

    function _checkAllowance(
        address _spender,
        address _token,
        uint256 _amount
    ) internal {
        uint256 _currentAllowance = IERC20(_token).allowance(
            address(this),
            _spender
        );
        if (_currentAllowance < _amount) {
            IERC20(_token).safeIncreaseAllowance(
                _spender,
                _amount - _currentAllowance
            );
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfFidu() public view returns (uint256) {
        return FIDU.balanceOf(address(this));
    }
}
