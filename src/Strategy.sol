// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.12;

pragma experimental ABIEncoderV2;

import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {IERC20Metadata} from "@yearnvaults/contracts/yToken.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

import "./interfaces/Curve/IStableSwapExchange.sol";
import "./interfaces/Goldfinch/ISeniorPool.sol";
import "./interfaces/Goldfinch/IStakingRewards.sol";
import "./interfaces/Uniswap/IUniV3.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // ---------------------- STATE VARIABLES ----------------------

    IERC20 public constant FIDU =
        IERC20(0x6a445E9F40e0b97c92d0b8a3366cEF1d67F700BF);
    IERC20 public constant GFI =
        IERC20(0xdab396cCF3d84Cf2D07C4454e10C8A6F5b008D2b);
    IERC20 public constant USDC =
        IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint24 internal constant uniPoolFeeGFI = 3_000; // this is equal to 0.3%
    uint24 internal constant uniPoolFeeWETH = 500; // this is equal to 0.05%
    address public constant uniswapv3 =
        address(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);

    uint256 internal constant MAX_BIPS = 10_000;
    bool internal forceHarvestTriggerOnce; // only set this to true when we want to trigger our keepers to harvest for us

    IStableSwapExchange public constant curvePool =
        IStableSwapExchange(0x80aa1a80a30055DAA084E599836532F3e58c95E2);
    ISeniorPool public constant seniorPool =
        ISeniorPool(0x8481a6EbAf5c7DABc3F7e09e44A89531fd31F822);
    IStakingRewards public constant stakingRewards =
        IStakingRewards(0xFD6FF39DA508d281C2d255e9bBBfAb34B6be60c3);

    uint256 public maxSlippageWantToFidu;
    uint256 public maxSlippageFiduToWant;
    uint256 public maxSingleGFISwap;
    uint256 public tokenId;
    bool public assessTrueHoldings;

    // ---------------------- CONSTRUCTOR ----------------------

    constructor(address _vault) public BaseStrategy(_vault) {
        _initializeStrat();
    }

    function _initializeStrat() internal {
        maxSlippageWantToFidu = 30;
        maxSlippageFiduToWant = 30;
        maxSingleGFISwap = 500;
        assessTrueHoldings = false;
    }

    function name() external view override returns (string memory) {
        return "StrategyGoldfinchUSDC";
    }

    // ---------------------- MAIN ----------------------

    // Calculate FIDU value based on Curve's price_oracle
    function estimatedTotalAssets() public view override returns (uint256) {
        uint256 _balanceOfFidu = balanceOfAllFidu();
        if (_balanceOfFidu == 0) {
            return balanceOfWant();
        } else {
            return balanceOfWant() + (_balanceOfFidu * 1e6 / curvePool.price_oracle());
        }
    }

    // Calculate FIDU value based on Goldfinch's sharePrice, minus 0.5% withdraw fee
    // not used, for public view only
    function estimatedTotalAssetsAtSharePrice()
        public
        view
        returns (uint256)
    {
        uint256 _balanceOfFidu = balanceOfAllFidu();
        if (_balanceOfFidu == 0) {
            return balanceOfWant();
        } else {
            return balanceOfWant() + (_balanceOfFidu * seniorPool.sharePrice() * 995 / 1000);
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        uint256 _initialBalanceOfWant = balanceOfWant();
        _claimRewards();
        _sellRewardsOnUniswap();

        // Case 1 - assessTrueHoldings flag set to true (Curve pool mostly in line)
        if (assessTrueHoldings) {
            uint256 _totalAssets = estimatedTotalAssets();
            if (_totalAssets >= _totalDebt) {
                _profit = _totalAssets - _totalDebt;
            } else {
                _loss = _totalDebt - _totalAssets;
            }

            // free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
            uint256 _toFree = _debtOutstanding + _profit;
            // liquidate some of the Want
            uint256 _balanceOfWant = balanceOfWant();
            if (_balanceOfWant < _toFree) {
                // liquidation could result in a profit
                (uint256 _liquidationProfit, uint256 _liquidationLoss) =
                    withdrawSome(_toFree - _balanceOfWant);

                // update the P&L to account for liquidation
                _loss += _liquidationLoss;
                _profit += _liquidationProfit;
            }
        // Case 2 - assessTrueHoldings flag set to false (Curve pool out of line)
        // in this case we just look for delta in balanceOfWant after selling rewards
        } else {
            _profit = balanceOfWant() - _initialBalanceOfWant;
        }

        uint256 _liquidWant = balanceOfWant();

        // calculate final p&l and _debtPayment

        // enough to pay profit (partial or full) only
        if (_liquidWant <= _profit) {
            _profit = _liquidWant;
            _debtPayment = 0;
        // enough to pay for all profit and _debtOutstanding (partial or full)
        } else {
            _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
        }

        if (_loss > _profit) {
            _loss -= _profit;
            _profit = 0;
        } else {
            _profit -= _loss;
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToInvest = _liquidWant - _debtOutstanding;
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
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant < _amountNeeded) {
            uint256 _fiduToSwap =
            Math.min(_amountNeeded * curvePool.price_oracle() / 1e6, balanceOfAllFidu());
            _swapFiduToWant(_fiduToSwap);
        } else {
            return (_amountNeeded, 0);
        }
        _liquidWant = balanceOfWant();
        if (_liquidWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
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
        uint256 _fiduToSwap = _amountNeeded * curvePool.price_oracle() / 1e6;
        _swapFiduToWant(_fiduToSwap);
        uint256 _estimatedTotalAssetsAfter = estimatedTotalAssets();
        if (_estimatedTotalAssetsAfter >= _estimatedTotalAssetsBefore) {
            return (_estimatedTotalAssetsAfter - _estimatedTotalAssetsBefore, 0);
        } else {
            return (0, _estimatedTotalAssetsBefore - _estimatedTotalAssetsAfter);
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _swapFiduToWant(balanceOfAllFidu());
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstakeAllFidu();
        FIDU.safeTransfer(_newStrategy, FIDU.balanceOf(address(this)));
        GFI.safeTransfer(_newStrategy, GFI.balanceOf(address(this)));
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {}

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
    function swapFiduToWant(uint256 fiduAmount) external onlyVaultManagers {
        _swapFiduToWant(fiduAmount);
    }

    function swapWantToFidu(uint256 wantAmount) external onlyVaultManagers {
        _swapWantToFidu(wantAmount);
    }

    function setMaxSlippageWantToFidu(uint256 _maxSlippageWantToFidu)
        external
        onlyVaultManagers
    {
        maxSlippageWantToFidu = _maxSlippageWantToFidu;
    }

    function setMaxSlippageFiduToWant(uint256 _maxSlippageFiduToWant)
        external
        onlyVaultManagers
    {
        maxSlippageFiduToWant = _maxSlippageFiduToWant;
    }

    function setAssessTrueHoldings(bool _assessTrueHoldings)
        external
        onlyVaultManagers
    {
        assessTrueHoldings = _assessTrueHoldings;
    }

    function setMaxSingleGFISwap(uint256 _maxSingleGFISwap)
        external
        onlyVaultManagers
    {
        maxSingleGFISwap = _maxSingleGFISwap;
    }

    // ---------------------- KEEP3RS ----------------------
    // use this to determine when to harvest

    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    // check if the current baseFee is below our external target
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyVaultManagers
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    // ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------
    function _swapFiduToWant(uint256 _fiduAmount) internal {
        uint256 _fiduValueInWant =
            _fiduAmount * seniorPool.sharePrice() * 995 / 1000 / 1e30;
        uint256 _expectedOut = curvePool.get_dy(0, 1, _fiduAmount);
        uint256 _allowedSlippageLoss =
            _fiduValueInWant * maxSlippageFiduToWant / MAX_BIPS;
        if (_fiduValueInWant - _allowedSlippageLoss > _expectedOut) {
            return;
        } else {
            if (tokenId != 0) {
                uint256 _fiduToUnstake =
                    Math.min(0,_fiduAmount - FIDU.balanceOf(address(this)));
                if (stakingRewards.stakedBalanceOf(tokenId) <= _fiduToUnstake) {
                    stakingRewards.unstake(tokenId, stakingRewards.stakedBalanceOf(tokenId));
                } else {
                    stakingRewards.unstake(tokenId, _fiduToUnstake);
                }
            }
            _checkAllowance(address(curvePool), address(FIDU), _fiduAmount);
            curvePool.exchange_underlying(0, 1, _fiduAmount, _expectedOut);
        }
    }

    function _swapWantToFidu(uint256 _amount) internal {
        uint256 _expectedFiduOut = curvePool.get_dy(1, 0, _amount);
        uint256 _expectedValueOut =
            _expectedFiduOut * seniorPool.sharePrice() * 995 / 1000 / 1e18;
        uint256 _allowedSlippageLoss =
            _amount * maxSlippageWantToFidu / MAX_BIPS;
        if (_amount - _allowedSlippageLoss > _expectedValueOut / 1e12) {
            return;
        } else {
            if (_amount > 0) {
                _checkAllowance(address(curvePool), address(want), _amount);
                curvePool.exchange_underlying(1, 0, _amount, _expectedFiduOut);
            }
        }
    }

    function _stakeFidu(uint256 _amountToStake) internal {
        _checkAllowance(address(stakingRewards), address(FIDU), _amountToStake);
        if (tokenId == 0) { // we don't have a tokenId
            tokenId = stakingRewards.stake(_amountToStake, 0);
        } else {
            stakingRewards.addToStake(tokenId, _amountToStake);
        }
    }

    function _unstakeAllFidu() internal {
        if (tokenId != 0) {
            _claimRewards();
            uint256 _amountToUnstake = stakingRewards.stakedBalanceOf(tokenId);
            stakingRewards.unstake(tokenId, _amountToUnstake);
        }
    }

    function unstakeAllFidu() external onlyVaultManagers {
        _unstakeAllFidu();
    }

    function _claimRewards() internal {
        if (tokenId != 0) {
            stakingRewards.getReward(tokenId);
        }
    }

    function _sellRewardsOnUniswap() internal {
        uint256 _gfiToSwap =
            Math.min(maxSingleGFISwap, GFI.balanceOf(address(this)));
        if (_gfiToSwap > 1e17) { // don't want to swap dust or we might revert
            _checkAllowance(address(uniswapv3), address(GFI), _gfiToSwap);
            IUniV3(uniswapv3).exactInput(
                        // hop from GFI/WETH(0.3%) then WETH/USDC (0.05%)
                        IUniV3.ExactInputParams(
                            abi.encodePacked(
                                address(GFI),
                                uniPoolFeeGFI,
                                address(WETH),
                                uniPoolFeeWETH,
                                address(USDC)
                            ),
                            address(this),
                            block.timestamp,
                            _gfiToSwap,
                            uint256(1)
                        )
                    );
        }
    }

    function manuallyClaimRewards() external onlyVaultManagers {
        _claimRewards();
    }

    function _checkAllowance(address _contract, address _token, uint256 _amount)
        internal
    {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfAllFidu() public view returns (uint256) {
        uint256 _balanceOfAllFidu;
        uint256 _totalStakedFidu;
        if (tokenId != 0) {
            _totalStakedFidu =
                _totalStakedFidu + stakingRewards.stakedBalanceOf(tokenId);
        }
        _balanceOfAllFidu = FIDU.balanceOf(address(this)) + _totalStakedFidu;
        return _balanceOfAllFidu;
    }

    function claimableRewards() public view returns (uint256) {
        uint256 _claimableRewards;
        _claimableRewards = stakingRewards.optimisticClaimable(tokenId);
        return _claimableRewards;
    }
}