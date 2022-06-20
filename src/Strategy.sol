// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./interfaces/Curve/IStableSwapExchange.sol";
import "./interfaces/Goldfinch/ISeniorPool.sol";
import "./interfaces/Goldfinch/IStakingRewards.sol";
import "./interfaces/ySwap/ITradeFactory.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using Counters for Counters.Counter;
    using EnumerableSet for EnumerableSet.UintSet;

// ---------------------- STATE VARIABLES ----------------------

    IERC20 public constant FIDU = IERC20(0x6a445E9F40e0b97c92d0b8a3366cEF1d67F700BF);
    IERC20 public constant GFI = IERC20(0xdab396cCF3d84Cf2D07C4454e10C8A6F5b008D2b);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 internal constant MAX_BIPS = 10_000;

    Counters.Counter public tokenIdCounter; // NFT position for staked Fidu
    EnumerableSet.UintSet private _tokenIdList; // Creating a set to store _tokenId's

    IStableSwapExchange public curvePool = IStableSwapExchange(0x80aa1a80a30055DAA084E599836532F3e58c95E2);
    ISeniorPool public seniorPool = ISeniorPool(0x8481a6EbAf5c7DABc3F7e09e44A89531fd31F822);
    IStakingRewards public stakingRewards = IStakingRewards(0xFD6FF39DA508d281C2d255e9bBBfAb34B6be60c3);

    uint256 public maxSlippageWantToFidu;   
    uint256 public maxSlippageFiduToWant;     
    uint256 public maxSingleInvest;

    address public tradeFactory = address(0);

// ---------------------- CONSTRUCTOR ----------------------

    constructor(
        address _vault
    ) public BaseStrategy(_vault) {
         _initializeStrat();
    }

    function _initializeStrat() internal { // runs only once at contract deployment
        maxSlippageWantToFidu = 30;
        maxSlippageFiduToWant = 50;           
        maxSingleInvest = 10_000 * 1e6;
    }

    function name() external view override returns (string memory) {
        return "StrategyGoldfinchUSDC";
    }

// ---------------------- MAIN ----------------------

     // Calculate the Fidu value based on estimated Curve output
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 _balanceOfFidu = balanceOfAllFidu();
        if (_balanceOfFidu  == 0) {
            return balanceOfWant();
        } else {
            return balanceOfWant() + curvePool.get_dy(0, 1, _balanceOfFidu);
        }
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
        // run initial profit + loss calculations based on Curve pool rate
        // if Curve rate > sharePrice, we report a profit, else we report a loss
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        if (_totalAssets >= _totalDebt) {
            _profit = _totalAssets - _totalDebt;
            _loss = 0;
        } else {
            _loss = _totalDebt - _totalAssets;
            _profit = 0;
        }
        _debtPayment = _debtOutstanding;
        // free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
        uint256 _liquidWant = balanceOfWant();
        uint256 _toFree = _debtOutstanding + _profit;
        if (_liquidWant < _toFree) {
            (uint256 _liquidationProfit, uint256 _liquidationLoss) = withdrawSome(_toFree);
            _loss = _loss + _liquidationLoss;
            _profit = _liquidationProfit;
            _liquidWant = balanceOfWant();
            if (_liquidWant < _toFree){
                _debtPayment = _liquidWant;
            }
        }
        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }    
    }

    function adjustPosition(uint256 _debtOutstanding) internal override { 
        _claimRewards(); 
        uint256 _liquidWant = balanceOfWant(); 
        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToInvest =  Math.min(_liquidWant - _debtOutstanding, maxSingleInvest);
            _swapWantToFidu(_amountToInvest);
        }
        uint256 unstakedBalance = FIDU.balanceOf(address(this)); // stake any unstaked Fidu
        if (unstakedBalance > 0) {
            _stakeFidu(unstakedBalance);
        }        
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _amountNeededAllowed = Math.min(_amountNeeded, estimatedTotalAssets()); // This makes it safe to request to liquidate more than we have 
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant < _amountNeededAllowed) {
            uint256 _fiduToSwap = Math.min((curvePool.get_dy(1, 0, _amountNeededAllowed)), balanceOfAllFidu());
            _swapFiduToWant(_fiduToSwap, true); // _force set to true, as we skip slippage check for withdraw and emergencyShutdown
        } else {
             return (_amountNeededAllowed, 0);
        }
        _liquidWant = balanceOfWant();
        if (_liquidWant >= _amountNeededAllowed) {
            _liquidatedAmount = _amountNeededAllowed;
        } else {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded - _liquidWant;
        }
    }

    function withdrawSome(uint256 _amountNeeded)
        internal
        returns (uint256 _liquidationProfit, uint256 _liquidationLoss)
    {
        uint256 _estimatedTotalAssetsBefore = estimatedTotalAssets();
        uint256 _amountNeededAllowed = Math.min(_amountNeeded, balanceOfAllFidu()); // This makes it safe to request to liquidate more than we have 
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant < _amountNeededAllowed) {
            uint256 _fiduToSwap = (curvePool.get_dy(1, 0, _amountNeededAllowed));
            _swapFiduToWant(_fiduToSwap, false);
            _liquidWant = balanceOfWant();
            uint256 _estimatedTotalAssets = estimatedTotalAssets();
            if (_estimatedTotalAssets >= _estimatedTotalAssetsBefore) {
                return (estimatedTotalAssets() - _estimatedTotalAssetsBefore, 0);
            } else { 
                return (0, _estimatedTotalAssetsBefore - estimatedTotalAssets());
            }
        } else { 
            return (0,0);
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _swapFiduToWant(balanceOfAllFidu(), true);
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstakeAllFidu();
        _claimRewards();
        FIDU.safeTransfer(_newStrategy, FIDU.balanceOf(address(this)));
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
    
// ---------------------- MANAGEMENT FUNCTIONS ----------------------
    function swapFiduToWant(uint256 FiduAmount, bool force) external onlyVaultManagers {
        _swapFiduToWant(FiduAmount, force);
    }

    function setMaxSlippageWantToFidu(uint256 _maxSlippageWantToFidu) external onlyVaultManagers {
        maxSlippageWantToFidu = _maxSlippageWantToFidu;
    }

    function setMaxSlippageFiduToWant(uint256 _maxSlippageFiduToWant) external onlyVaultManagers {
        maxSlippageFiduToWant = _maxSlippageFiduToWant;
    }

    function setMaxSingleInvest(uint256 _maxSingleInvest) external onlyVaultManagers {
        maxSingleInvest = _maxSingleInvest;
    }

// ---------------------- YSWAPS FUNCTIONS ----------------------
    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }
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

// ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------
    function _swapFiduToWant(uint256 _fiduAmount, bool _force) internal {
        uint256 _fiduValueInWant = (_fiduAmount * seniorPool.sharePrice()) / 1e30;
        uint256 _expectedOut = curvePool.get_dy(0, 1, _fiduAmount); 
        uint256 _allowedSlippageLoss = (_fiduValueInWant * maxSlippageFiduToWant) / MAX_BIPS;
        if (!_force && _fiduValueInWant - _allowedSlippageLoss > _expectedOut) { 
            return;
        } else {
            // Loop through _tokenId's and unstake until we get the amount of _fiduAmount required
            uint256 _fiduToUnstake = _fiduAmount - FIDU.balanceOf(address(this));
            while (_fiduToUnstake > 0 && _tokenIdList.length() > 0) {
                uint256 _stakeId = _tokenIdList.at(0);               
                if (stakingRewards.stakedBalanceOf(_stakeId) <= _fiduToUnstake) {
                    stakingRewards.unstake(_stakeId, stakingRewards.stakedBalanceOf(_stakeId));
                    _tokenIdList.remove(_stakeId);
                } else {
                    stakingRewards.unstake(_stakeId, _fiduToUnstake); 
                }
                _fiduToUnstake = _fiduAmount - FIDU.balanceOf(address(this));
            }
            _checkAllowance(address(curvePool), address(FIDU), _fiduAmount); 
            curvePool.exchange_underlying(0, 1, _fiduAmount, _expectedOut);
        }
    }
    
    function _swapWantToFidu(uint256 _amount) internal {
        uint256 _expectedOut = curvePool.get_dy(1, 0, _amount);
        uint256 _expectedValueOut = (_expectedOut * seniorPool.sharePrice()) / 1e18;
        uint256 _allowedSlippageLoss = (_amount * maxSlippageWantToFidu) / MAX_BIPS;
        if (_amount - _allowedSlippageLoss > _expectedValueOut) { 
            return;
        } else {
            if (_amount > 0){      
                _checkAllowance(address(curvePool), address(want), _amount); 
                curvePool.exchange_underlying(1, 0, _amount, _expectedOut); 
            }
        }
    }

    function _stakeFidu(uint256 _amountToStake) internal {
        _checkAllowance(address(stakingRewards), address(FIDU), _amountToStake);
        stakingRewards.stake(_amountToStake, 0);
        updateTokenIdCounter();
        uint256 _tokenId = tokenIdCounter.current(); // Hack: they don't return the token ID from the stake function, so we need to calculate it
        _tokenIdList.add(_tokenId); // each time we stake Fidu, a new _tokenId is created
    }

    function _unstakeAllFidu() internal {
        for (uint16 i = 0; i < _tokenIdList.length(); i++) {
            uint256 _stakeId = _tokenIdList.at(i);
            uint256 _amountToUnstake = stakingRewards.stakedBalanceOf(_stakeId);
            stakingRewards.unstake(_stakeId, _amountToUnstake);
            _tokenIdList.remove(_stakeId);
        }
    }

    function unstakeAllFidu() external onlyVaultManagers {
        _unstakeAllFidu();
    }

    function _claimRewards() internal {
        for (uint16 i = 0; i < _tokenIdList.length(); i++) {
            uint256 _stakeId = _tokenIdList.at(i);
            stakingRewards.getReward(_stakeId);
            
        }   
    }

    function manuallyClaimRewards() external onlyVaultManagers {
        _claimRewards(); 
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
        for (uint16 i = 0; i < _tokenIdList.length(); i++) {
            _totalStakedFidu = _totalStakedFidu + stakingRewards.stakedBalanceOf(_tokenIdList.at(i));
        }
        _balanceOfAllFidu = FIDU.balanceOf(address(this)) + _totalStakedFidu;
        return _balanceOfAllFidu;
    }
}