// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
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
  
    event Cloned(address indexed clone);

    bool public isOriginal = true;

    IERC20 public constant Fidu = IERC20(0x6a445E9F40e0b97c92d0b8a3366cEF1d67F700BF);
    IERC20 public constant GFI = IERC20(0xdab396cCF3d84Cf2D07C4454e10C8A6F5b008D2b);

    Counters.Counter public tokenIdCounter; // NFT position for staked Fidu
    EnumerableSet.UintSet private _tokenIdList; // Creating a set to store _tokenId's
    
    uint256 internal constant MAX_BIPS = 10_000;
    uint256 public constant fiduDecimals = 1e18;

    // TODO: Remove
    IStableSwapExchange public curvePool = IStableSwapExchange(0x80aa1a80a30055DAA084E599836532F3e58c95E2);
    ISeniorPool public seniorPool = ISeniorPool(0x8481a6EbAf5c7DABc3F7e09e44A89531fd31F822);
    IStakingRewards public stakingRewards = IStakingRewards(0xFD6FF39DA508d281C2d255e9bBBfAb34B6be60c3);

    string internal strategyName;  
    uint256 public slippageProtectionIn;
    uint256 public maxSingleInvest;
    uint256 public wantDecimalsAdj;
    address public tradeFactory = address(0); 

    constructor(
        address _vault,
        uint256 _slippageProtectionIn,
        uint256 _maxSingleInvest,
        uint256 _wantDecimalsAdj,
        address _tradeFactory,
        address _curvePool,
        address _seniorPool,
        address _stakingRewards,
        string memory _strategyName // TODO: NEEDED?
    ) public BaseStrategy(_vault) {
         _initializeStrat(_slippageProtectionIn, _maxSingleInvest, _wantDecimalsAdj, _tradeFactory, _curvePool, _seniorPool, _stakingRewards, _strategyName);
    }

    function _initializeStrat( // called by constructor
        uint256 _slippageProtectionIn,
        uint256 _maxSingleInvest,
        uint256 _wantDecimalsAdj,
        address _tradeFactory,
        address _curvePool,
        address _seniorPool,
        address _stakingRewards,
        string memory _strategyName // TODO: NEEDED?
    ) internal {
        tradeFactory = _tradeFactory; // TODO: NEEDED?
        slippageProtectionIn = 30;
        maxSingleInvest = 50_000;
        wantDecimalsAdj = 1e12;
        curvePool = address(0x80aa1a80a30055DAA084E599836532F3e58c95E2);
        seniorPool = address(0x8481a6EbAf5c7DABc3F7e09e44A89531fd31F822);
        stakingRewards = address(0xFD6FF39DA508d281C2d255e9bBBfAb34B6be60c3);
        // TODO: DO we need to set trade factory here?
    }

    function initialize( // called by clone
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _slippageProtectionIn,
        uint256 _maxSingleInvest,
        uint256 _wantDecimalsAdj,
        address _tradeFactory,
        address _curvePool,
        address _seniorPool,
        address _stakingRewards,
        string memory _strategyName // TODO: NEEDED?
    ) external {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(
            _slippageProtectionIn,
            _maxSingleInvest,
            _wantDecimalsAdj,
            _tradeFactory,
            _curvePool,
            _seniorPool,
            _stakingRewards,
            _strategyName // TODO: NEEDED?
        );
    }

    function cloneGoldfinch(
            address _vault,
            address _strategist,
            address _rewards,
            address _keeper,
            uint256 _slippageProtectionIn,
            uint256 _maxSingleInvest,
            uint256 _wantDecimalsAdj,
            address _tradeFactory,
            address _curvePool,
            address _seniorPool,
            address _stakingRewards,
            string memory _strategyName // TODO: NEEDED?
        ) external returns (address newStrategy) {
            require(isOriginal, "!clone");
            bytes20 addressBytes = bytes20(address(this));

            assembly {
                // EIP-1167 bytecode
                let clone_code := mload(0x40)
                mstore(
                    clone_code,
                    0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
                )
                mstore(add(clone_code, 0x14), addressBytes)
                mstore(
                    add(clone_code, 0x28),
                    0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
                )
                newStrategy := create(0, clone_code, 0x37)
            }

            Strategy(newStrategy).initialize(
                _vault,
                _strategist,
                _rewards,
                _keeper,
                _slippageProtectionIn,
                _maxSingleInvest,
                _wantDecimalsAdj,
                _tradeFactory,
                _curvePool,
                _seniorPool,
                _stakingRewards,
                _strategyName
            );

            emit Cloned(newStrategy);
        }

    function name() external view override returns (string memory) {
        return "StrategyGoldfinchUSDC";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + (curvePool.get_dy(0, 1, balanceOfAllFidu())/ fiduDecimals) / wantDecimalsAdj;
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

        // run initial profit + loss calculations.
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        if (_totalAssets >= _totalDebt) {
            _profit = _totalAssets - _totalDebt;
        } else {
            _loss = _totalDebt - _totalAssets;
        }

        // free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
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

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToInvest =  _liquidWant - _debtOutstanding;
            _swapWantToFidu(_amountToInvest);
        }
        // stake any unstaked Fidu
        uint256 unstakedBalance = Fidu.balanceOf(address(this));
        if (unstakedBalance > 0) {
            _stakeFidu(unstakedBalance);
        }
        // claim rewards
        _claimRewards();
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
        _swapFiduToWant(_fiduToSwap);
        _liquidWant = balanceOfWant();

        if (_liquidWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded - _liquidWant;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _swapFiduToWant(balanceOfAllFidu());
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstakeAllFidu();
        _claimRewards();
        Fidu.safeTransfer(_newStrategy, Fidu.balanceOf(address(this)));
        GFI.safeTransfer(_newStrategy, GFI.balanceOf(address(this)));
        }

    function protectedTokens() internal view virtual returns (address[] memory);
    // solhint-disable-next-line no-empty-blocks
    
    function ethToWant(uint256 _amtInWei) public view virtual returns (uint256);
    
    // ----------- MANAGEMENT FUNCTIONS -----------
    function swapFiduToWant(uint256 FiduAmount) external onlyVaultManagers {
        _swapFiduToWant(FiduAmount);
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

    // ---------------------- SETTERS -----------------------
    
    function setCurvePoolContract(address _curvePool) external onlyVaultManagers {
        curvePool = _curvePool;
    }

    function setSeniorPoolContract(address _seniorPool) external onlyVaultManagers {
        seniorPool = _seniorPool;
    }

    function setStakingRewardsContract(address _stakingRewards) external onlyVaultManagers {
        stakingRewards = _stakingRewards;
    }

    function setSlippageProtectionIn(uint256 _slippageProtectionIn) external onlyVaultManagers {
        slippageProtectionIn = _slippageProtectionIn;
    }

    function setWantDecimalsAdj(uint256 _wantDecimalsAdj) external onlyVaultManagers {
        wantDecimalsAdj = _wantDecimalsAdj;
    }

    function setMaxSingleInvest(uint256 _maxSingleInvest) external onlyVaultManagers {
        maxSingleInvest = _maxSingleInvest;
    }

    // ------- HELPER AND UTILITY FUNCTIONS -------
    function _swapFiduToWant(uint256 _fiduAmount) internal {
        uint256 _expectedOut = curvePool.get_dy(0, 1, _fiduAmount); 
        uint256 _fiduToUnstake = Math.max(_fiduAmount - Fidu.balanceOf(address(this)),0);
        while (_fiduToUnstake > 0 && _tokenIdList.length() > 0) {
            uint256 _stakeId = _tokenIdList.at(0);               
            if (stakingRewards.stakedBalanceOf(_stakeId) <= _fiduToUnstake) { // unstake entirety of this _stakeId
                stakingRewards.unstake(_stakeId, stakingRewards.stakedBalanceOf(_stakeId));
                _tokenIdList.remove(_stakeId); // remove _stakeId from the list
            } else { // partial unstake
                stakingRewards.unstake(_stakeId, _fiduToUnstake); 
            }
            _fiduToUnstake = _fiduAmount - Fidu.balanceOf(address(this));
        }
        _checkAllowance(address(curvePool), address(Fidu), _fiduAmount); 
        curvePool.exchange_underlying(0, 1, _fiduAmount, _expectedOut);
    }
    
    function _swapWantToFidu(uint256 _amount) internal {
        uint256 _amountAllowed = Math.min(_amount, maxSingleInvest); // maxSingleInvest will be calc off-chain and set via onlyVaultManagers      
        uint256 _expectedOut = curvePool.get_dy(1, 0, _amountAllowed);
        uint256 _expectedValueOut = ((_expectedOut * seniorPool.sharePrice()) / fiduDecimals) / wantDecimalsAdj;
        uint256 _allowedSlippageLoss = (_amountAllowed * slippageProtectionIn) / MAX_BIPS;
        if (_amountAllowed - _allowedSlippageLoss > _expectedValueOut) { 
            return;
        } else {
            if (_amountAllowed > 0){      
                _checkAllowance(address(curvePool), address(want), _amountAllowed); 
                curvePool.exchange_underlying(1, 0, _amountAllowed, _expectedOut); 
            }
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
        for (uint16 i = 0; i < _tokenIdList.length(); i++) { // check claimable GFI for each tokenId
            uint256 _stakeId = _tokenIdList.at(i);
            if (stakingRewards.claimableRewards(_stakeId) != 0) { 
                stakingRewards.getReward(_stakeId); // claim GFI
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
        for (uint16 i = 0; i < _tokenIdList.length(); i++) {
            _totalStakedFidu = _totalStakedFidu + stakingRewards.stakedBalanceOf(_tokenIdList.at(i));
        }
        _balanceOfAllFidu = Fidu.balanceOf(address(this)) + _totalStakedFidu;
        return _balanceOfAllFidu;
    }

}
