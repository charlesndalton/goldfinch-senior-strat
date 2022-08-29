// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import "forge-std/console2.sol";

import {StrategyFixture} from "./utils/StrategyFixture.sol";

// for whale testing
import "../interfaces/Curve/IStableSwapExchange.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

IStableSwapExchange constant curvePool =
    IStableSwapExchange(0x80aa1a80a30055DAA084E599836532F3e58c95E2);
IERC20 constant FIDU = IERC20(0x6a445E9F40e0b97c92d0b8a3366cEF1d67F700BF);

//
contract StrategyOperationsTest is StrategyFixture {
    // setup is run on before each test
    function setUp() public override {
        // setup vault
        super.setUp();
    }

    function testSetupVaultOK() public {
        console2.log("address of vault", address(vault));
        assertTrue(address(0) != address(vault));
        assertEq(vault.token(), address(want));
        assertEq(vault.depositLimit(), type(uint256).max);
    }

    // TODO: add additional check on strat params
    function testSetupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(address(strategy.vault()), address(vault));
    }

    /// Test Operations
    function testStrategyOperation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        uint256 balanceBefore = want.balanceOf(address(user));
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        skip(3 minutes);
        vm.prank(strategist);
        strategy.harvest();

        // tend
        vm.prank(strategist);
        strategy.tend();

        vm.startPrank(user);
        vault.withdraw(vault.balanceOf(user), user, 600);
        vm.stopPrank();

        assertRelApproxEq(want.balanceOf(user), balanceBefore, DELTA);
    }

    function testEmergencyExit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // set emergency and exit
        vm.prank(gov);
        strategy.setEmergencyExit();
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertLt(strategy.estimatedTotalAssets(), _amount);
    }

    function testProfitableHarvest(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // have a whale swap a bunch of FIDU -> USDC, so we get a preferable rate

        uint256 _whaleFIDUToSell = 1_000_000 * 1e18;
        deal(address(FIDU), whale, _whaleFIDUToSell);
        vm.startPrank(whale);
        FIDU.approve(address(curvePool), _whaleFIDUToSell);
        curvePool.exchange_underlying(0, 1, _whaleFIDUToSell, 0);
        vm.stopPrank();

        // Deposit to the vault
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        uint256 beforePps = vault.pricePerShare();

        // have whale swap his USDC back to FIDU, so we should be able to declare profits

        uint256 _whaleUSDCToSell = want.balanceOf(whale);
        vm.startPrank(whale);
        want.approve(address(curvePool), _whaleUSDCToSell);
        curvePool.exchange_underlying(1, 0, _whaleUSDCToSell, 0);
        vm.stopPrank();

        // Harvest 1: Send funds through the strategy
        console2.log("Send funds through the strategy");
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // Harvest 2: Send funds through the strategy
        console2.log("--> Fast forward 5 days");
        skip(60*24*50); // skip 5 days
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // Harvest 3: Realize profit
        console2.log("--> Fast forward 10 days");
        skip(60*24*100); // skip 10 days
        vm.prank(strategist);
        strategy.harvest();

        // Testing GFI rewards
        assertGe(GFI.balanceOf(address(strategy)),1);
        console2.log("GFI reward obtained:", GFI.balanceOf(address(strategy))); // uint256 profit = want.balanceOf(address(vault));
        // assertGe(vault.pricePerShare(), beforePps);
    // Check if profitable
    }

    function testDebtPaymentWithProfit(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Step 1: have a whale swap a bunch of FIDU -> USDC, so we get a preferable rate

        uint256 _whaleFIDUToSell = 10_000_000 * 1e18;
        deal(address(FIDU), whale, _whaleFIDUToSell);
        vm.startPrank(whale);
        FIDU.approve(address(curvePool), _whaleFIDUToSell);
        curvePool.exchange_underlying(0, 1, _whaleFIDUToSell, 0);
        vm.stopPrank();

        // Step 2: deposit to strat and harvest, so we can scoop up some of that FIDU

        vm.startPrank(user);
        want.approve(address(vault), _amount);
        vault.deposit(_amount);
        vm.stopPrank();

        skip(1);
        vm.prank(strategist);
        strategy.harvest();

        // Step 3: have whale swap his USDC back to FIDU, so we should be able to declare profits

        uint256 _whaleUSDCToSell = want.balanceOf(whale);
        vm.startPrank(whale);
        want.approve(address(curvePool), _whaleUSDCToSell);
        curvePool.exchange_underlying(1, 0, _whaleUSDCToSell, 0);
        vm.stopPrank();

        // Step 4: decrease debt ratio before harvesting, then harvest profit

        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
    }

    function testChangeDebt(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault and harvest
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        uint256 half = uint256(_amount / 2);
        assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);

        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 10_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA); // TODO: uncomment the following lines.
        // vm.prank(gov);
        // vault.updateStrategyDebtRatio(address(strategy), 5_000);
        // skip(1);
        // vm.prank(strategist);
        // strategy.harvest();
        // assertRelApproxEq(strategy.estimatedTotalAssets(), half, DELTA);
    // In order to pass these tests, you will need to implement prepareReturn.
    }

    function testSweep(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Strategy want token doesn't work
        vm.prank(user);
        want.transfer(address(strategy), _amount);
        assertEq(address(want), address(strategy.want()));
        assertGt(want.balanceOf(address(strategy)), 0);

        vm.prank(gov);
        vm.expectRevert("!want");
        strategy.sweep(address(want));

        // Vault share token doesn't work
        vm.prank(gov);
        vm.expectRevert("!shares");
        strategy.sweep(address(vault));

        // TODO: If you add protected tokens to the strategy.
        // Protected token doesn't work
        // vm.prank(gov);
        // vm.expectRevert("!protected");
        // strategy.sweep(strategy.protectedToken());

        uint256 beforeBalance = weth.balanceOf(gov);
        uint256 wethAmount = 1 ether;
        deal(address(weth), user, wethAmount);
        vm.prank(user);
        weth.transfer(address(strategy), wethAmount);
        assertNeq(address(weth), address(strategy.want()));
        assertEq(weth.balanceOf(user), 0);
        vm.prank(gov);
        strategy.sweep(address(weth));
        assertRelApproxEq(
            weth.balanceOf(gov),
            wethAmount + beforeBalance,
            DELTA
        );
    }

    function testTriggers(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);
        // Deposit to the vault and harvest
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        vm.prank(gov);
        vault.updateStrategyDebtRatio(address(strategy), 5_000);
        skip(1);
        vm.prank(strategist);
        strategy.harvest();
        strategy.harvestTrigger(0);
        strategy.tendTrigger(0);
    }
}