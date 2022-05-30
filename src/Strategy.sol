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

    IERC20 internal constant Fidu = IERC20(0x6a445E9F40e0b97c92d0b8a3366cEF1d67F700BF); //TODO: might change
    IERC20 internal constant GFI = IERC20(0xdab396cCF3d84Cf2D07C4454e10C8A6F5b008D2b); //TODO: might change

    Counters.Counter private tokenIdCounter; // NFT position for staked Fidu
    EnumerableSet.UintSet private _tokenIdList; // Creating a set to store _tokenId's

    address public tradeFactory = address(0);
    uint256 public maxSlippage;
    uint256 public bisectionPrecision;
    uint256 internal constant MAX_BIPS = 10_000;
    uint256 public wantDecimalsAdj = 1e12; // 1: no adjustment, 1e12: want has 6 decimals (i.e. USDC)
    uint256 public fiduDecimals = 1e18;

    // solhint-disable-next-line no-empty-blocks
    constructor(address _vault) BaseStrategy(_vault) {
        maxSlippage = 30; // Default to 30 bips
        bisectionPrecision = 100;
    }

    function name() external view override returns (string memory) {
        return "StrategyGoldfinchUSDC";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + ((balanceOfAllFidu() * seniorPool.sharePrice()) / fiduDecimals) / wantDecimalsAdj; // Fidu -> USDC decimals
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

    // Swap Want for Fidu if slippage conditions permit
    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToInvest =  (_liquidWant - _debtOutstanding);
            _swapWantToFidu(_amountToInvest);
        }
        // stake any unstaked Fidu
        uint256 unstakedBalance = Fidu.balanceOf(address(this));
        if (unstakedBalance > 0) {
            _stakeFidu(unstakedBalance);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        _amountNeeded = Math.min(_amountNeeded, estimatedTotalAssets()); // This makes it safe to request to liquidate more than we have 
        uint256 _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            return (_amountNeeded, 0);
        }
        uint256 _fiduToSwap = Math.min((_amountNeeded * (fiduDecimals*wantDecimalsAdj)) / seniorPool.sharePrice(), balanceOfAllFidu());
        _swapFiduToWant(_fiduToSwap, emergencyExit);
        _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded - _liquidWant;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _swapFiduToWant(balanceOfAllFidu(), true);
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstakeAllFidu();
        _claimRewards();
        Fidu.safeTransfer(_newStrategy, Fidu.balanceOf(address(this)));
        GFI.safeTransfer(_newStrategy, GFI.balanceOf(address(this)));
        }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {

    }
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

    function swapFiduToWant(uint256 FiduAmount, bool force) external onlyVaultManagers {
        _swapFiduToWant(FiduAmount, force);
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------
    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // Approve and set up trade factory
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
    // If slippage is too high and _force is false, find the maximum Fidu amount within maxSlippage using bisection method.
    // First we test for the _fiduAmount, if it results in too much slippage, we try half that amount.
    // It then iterates throught high/low trials until it's "close enough" (bisectionPrecision) to the optimal solution
    // TODO: check gas usage
    // If this function is too gas intensive, one option would be to calculate the amount off chain and harvest manually.

        uint256 _fiduValueInWant = (_fiduAmount * seniorPool.sharePrice()) / (fiduDecimals*wantDecimalsAdj);
        uint256 _expectedOut = curvePool.get_dy(0, 1, _fiduAmount); 
        uint256 _allowedSlippageLoss = (_fiduValueInWant * maxSlippage) / MAX_BIPS;
        
        if (!_force && _fiduValueInWant - _allowedSlippageLoss > _expectedOut) { 
            uint256 _high = _fiduAmount;
            uint256 _low = 1;
            uint256 _mid;       
            while ((_high - _low) > bisectionPrecision * (fiduDecimals*wantDecimalsAdj)) {
                _mid = (_high + _low)/2;
                _fiduValueInWant = (_mid * seniorPool.sharePrice()) / (fiduDecimals*wantDecimalsAdj);
                _expectedOut = curvePool.get_dy(0, 1, _mid); 
                _allowedSlippageLoss = (_fiduValueInWant * maxSlippage) / MAX_BIPS;
                if (_fiduValueInWant - _allowedSlippageLoss > _expectedOut) {
                    _fiduAmount = _mid;
                    _low = _mid;
                } else {
                    _high = _mid;
                }
            }
        }
        // Loop through _tokenId's and unstake until we get the amount of _fiduAmount required
        uint256 _fiduToUnstake = Math.max(_fiduAmount - Fidu.balanceOf(address(this)),0);
        while (_fiduToUnstake > 0 && _tokenIdList.length() > 0) {
            uint256 x = _tokenIdList.at(0);               
            if (stakingRewards.stakedBalanceOf(x) <= _fiduToUnstake) { // unstake entirety of this tokenId
                stakingRewards.unstake(x, stakingRewards.stakedBalanceOf(x));
               _tokenIdList.remove(x); // remove tokenId from the list
            } else { // partial unstake
                stakingRewards.unstake(x, _fiduToUnstake); }
            _fiduToUnstake = _fiduAmount - Fidu.balanceOf(address(this)); // is there a better way to update the remaining amount to unstake?
            
        }
        _checkAllowance(address(curvePool), address(Fidu), _fiduAmount); 
        curvePool.exchange_underlying(0, 1, _fiduAmount, _expectedOut);
    }
    

    function _swapWantToFidu(uint256 _amount) internal {
    // If slippage is too high and _force is false, find the maximum Fidu amount within maxSlippage using bisection method.
    // First we test for the _fiduAmount, if it results in too much slippage, we try half that amount.
    // It then iterates throught high/low trials until it's "close enough" (bisectionPrecision) to the optimal solution
    // TODO: check gas usage
    // If this function is too gas intensive, one option would be to calculate the amount off chain and harvest manually.

        uint256 _expectedOut = curvePool.get_dy(1, 0, _amount);
        uint256 _expectedValueOut = ((_expectedOut * seniorPool.sharePrice()) / fiduDecimals) / wantDecimalsAdj;
        uint256 _allowedSlippageLoss = (_amount * maxSlippage) / MAX_BIPS;

         if (_amount - _allowedSlippageLoss > _expectedValueOut) { 
            uint256 _high = _amount;
            uint256 _low = 1;
            uint256 _mid;        
            while ((_high - _low) > bisectionPrecision * (fiduDecimals*wantDecimalsAdj)) {
                _mid = (_high + _low)/2;
                _expectedValueOut = ((_mid* seniorPool.sharePrice()) / fiduDecimals) / wantDecimalsAdj;
                _expectedOut = curvePool.get_dy(1, 0, _mid);
                _allowedSlippageLoss = (_mid * maxSlippage) / MAX_BIPS;
                if (_mid - _allowedSlippageLoss > _expectedValueOut) {
                    _amount = _mid;
                    _low = _mid;
                } else {
                    _high = _mid;
                }
            }
        }
        if (_amount > 0){      
            _checkAllowance(address(curvePool), address(want), _amount); 
            curvePool.exchange_underlying(1, 0, _amount, _expectedOut); 
        }
    }

    function _stakeFidu(uint256 _amountToStake) internal {
        _checkAllowance(address(stakingRewards), address(Fidu), _amountToStake);

        stakingRewards.stake(_amountToStake, 0);
        updateTokenIdCounter();
        uint256 _tokenId = tokenIdCounter.current(); // Hack: they don't return the token ID from the stake function, so we need to calculate it
        _tokenIdList.add(_tokenId); // each time we stake Fidu, a new _tokenId is created
    }

    function _unstakeAllFidu() internal {
        for (uint i=0; i<_tokenIdList.length(); i++) {
            uint256 x = _tokenIdList.at(i);
            uint256 _amountToUnstake = stakingRewards.stakedBalanceOf(x);
            stakingRewards.unstake(x, _amountToUnstake);
            _tokenIdList.remove(x);
            }
    }

    function _claimRewards() internal {
        for (uint i=0; i<_tokenIdList.length(); i++) { // check claimable GFI for each tokenId
            uint256 x = _tokenIdList.at(i);
            if (stakingRewards.claimableRewards(x) != 0) { 
                stakingRewards.getReward(x); // claim GFI
            }
        }
    }

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
    
    function updateTokenIdCounter() internal {
        tokenIdCounter = stakingRewards._tokenIdTracker();
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfAllFidu() public view returns (uint256) {
        uint256 _balanceOfAllFidu;
        uint256 _totalStakedFidu;
        for (uint i=0; i<_tokenIdList.length(); i++) {
            _totalStakedFidu = _totalStakedFidu + stakingRewards.stakedBalanceOf(_tokenIdList.at(i));
        }
        _balanceOfAllFidu = Fidu.balanceOf(address(this)) + _totalStakedFidu;
        return _balanceOfAllFidu;
    }

}
