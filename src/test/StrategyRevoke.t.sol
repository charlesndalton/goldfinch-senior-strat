// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;

import {StrategyFixture} from "./utils/StrategyFixture.sol";

contract StrategyRevokeTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    function testRevokeStrategyFromVault(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        // set assessTrueHoldings flag to true
        vm.prank(management);
        strategy.setAssessTrueHoldings(true);

        // Deposit to the vault and harvest
        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        skip(1);

        // simulate whale swap on Curve to deposit at favorable rate
        simulateWhaleSellFIDU(10_000_000 * 1e18);

        vm.prank(strategist);
        strategy.harvest();
        assertGe(strategy.estimatedTotalAssets(), _amount);

        // simulate whale swap on Curve to withdraw at favorable rate
        simulateWhaleSellUSDC(10_000_000 * 1e6);

        vm.prank(gov);
        vault.revokeStrategy(address(strategy));
        skip(1);

        vm.prank(strategist);
        strategy.harvest();
        assertGe(want.balanceOf(address(vault)), _amount);
    }

    function testRevokeStrategyFromStrategy(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);
        deal(address(want), user, _amount);

        vm.prank(management);
        strategy.setAssessTrueHoldings(true);

        vm.prank(user);
        want.approve(address(vault), _amount);
        vm.prank(user);
        vault.deposit(_amount);
        skip(1);

        // simulate whale swap on Curve to deposit at favorable rate
        simulateWhaleSellFIDU(10_000_000 * 1e18);

        vm.prank(strategist);
        strategy.harvest();
        assertGe(strategy.estimatedTotalAssets(), _amount);

        vm.prank(gov);
        strategy.setEmergencyExit();
        skip(1);

        // simulate whale swap on Curve to withdraw at favorable rate
        simulateWhaleSellUSDC(10_000_000 * 1e6);

        vm.prank(strategist);
        strategy.harvest();
        assertGe(want.balanceOf(address(vault)), _amount);
    }
}