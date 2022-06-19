// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {StrategyFixture} from "./utils/StrategyFixture.sol";
import "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
IERC20 constant FIDU = IERC20(0x6a445E9F40e0b97c92d0b8a3366cEF1d67F700BF);


contract StrategyShutdownTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testVaultShutdownCanWithdraw(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        console2.log("testVaultShutdownCanWithdraw / USDC deposit (user)", _amount/1e6);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        uint256 bal = want.balanceOf(user);
        if (bal > 0) {
            vm.prank(user);
            want.transfer(address(0), bal);
        }

        // Harvest 1: Send funds through the strategy
        skip(7 hours);
        vm.prank(strategist);
        strategy.harvest();
        console2.log("testVaultShutdownCanWithdraw / Harvest");

        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // Set Emergency
        vm.prank(gov);
        vault.setEmergencyShutdown(true);
        console2.log("testVaultShutdownCanWithdraw / setEmergencyShutown()");
        // Withdraw (does it work, do you get what you expect)
        console2.log("testVaultShutdownCanWithdraw / vault.balanceOf(user)",vault.balanceOf(user)/1e6);
        vm.startPrank(user);
        vault.withdraw(vault.balanceOf(user), user, 300);
        vm.stopPrank();

        assertRelApproxEq(want.balanceOf(user), _amount, DELTA-100);
    }

    function testBasicShutdown(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // Deposit to the vault
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA);

        // Harvest 1: Send funds through the strategy
        skip(1 days);
        vm.prank(strategist);
        strategy.harvest();
        assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

        // Earn interest
        skip(1 days);

        // Harvest 2: Realize profit
        vm.prank(strategist);
        strategy.harvest();
        skip(6 hours);

        // Set emergency
        vm.prank(strategist);
        strategy.setEmergencyExit();

        vm.prank(strategist);
        strategy.harvest(); // Remove funds from strategy

        assertEq(want.balanceOf(address(strategy)), 0);
        assertRelApproxEq(want.balanceOf(address(vault)), _amount, DELTA); // The vault has all funds
        // NOTE: May want to tweak this based on potential loss during migration
    }
}
