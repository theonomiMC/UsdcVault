// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcVaultV1} from "../../src/upgradeable/UsdcVaultV1.sol";
import {UsdcVaultV2} from "../../src/upgradeable/UsdcVaultV2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract UsdcVaultV2Test is Test {
    UsdcVaultV2 public proxy;
    UsdcVaultV1 public vaultV1;
    MockERC20 public usdc;
    MockStrategy public strategy;

    address public owner = makeAddr("owner");
    address public toko = makeAddr("toko");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);

        // fund toko
        usdc.mint(toko, 2_000e6);

        // deploy V1
        vm.startPrank(owner);
        UsdcVaultV1 implV1 = new UsdcVaultV1();
        bytes memory data = abi.encodeWithSelector(
            UsdcVaultV1.initialize.selector, IERC20(address(usdc)), "Upgradeable USDC Vault", "uUSDC"
        );
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implV1), data);

        // interact with V1 before upgrade
        vaultV1 = UsdcVaultV1(address(proxyContract));
        vm.stopPrank();

        // 2. deposit in V1 BEFORE upgrade
        vm.startPrank(toko);
        usdc.approve(address(proxyContract), type(uint256).max);
        vaultV1.deposit(1000e6, toko);
        vm.stopPrank();

        // 3. upgrade to V2
        vm.startPrank(owner);
        UsdcVaultV2 implV2 = new UsdcVaultV2();
        vaultV1.upgradeToAndCall(address(implV2), "");

        // 4. wrap as V2
        proxy = UsdcVaultV2(address(proxyContract));

        // 5. set strategy
        strategy = new MockStrategy(address(usdc));
        proxy.setStrategy(strategy);
        vm.stopPrank();

        vm.prank(toko);
        usdc.approve(address(proxy), type(uint256).max);
    }

    function _runLossScenario(uint256 investAmount, uint256 lossAmount) internal {
        vm.prank(owner);
        proxy.invest(investAmount);

        // 2. Simulate the loss
        vm.prank(owner);
        strategy.simulateLoss(lossAmount);

        // 3. Act
        uint256 maxAvailable = proxy.maxWithdraw(toko);
        uint256 tokoBalanceBefore = usdc.balanceOf(toko);

        vm.prank(toko);
        proxy.withdraw(maxAvailable, toko, toko);

        // 4. Assertions
        // Ensure the user actually received the tokens
        assertEq(usdc.balanceOf(toko), tokoBalanceBefore + maxAvailable);
    }

    // -----------------------------------------------------------------------
    // 1. Upgrade path
    // -----------------------------------------------------------------------
    function test_upgrade_V1toV2_preservesState() public view {
        assertEq(proxy.balanceOf(toko), 1000e9);
        assertEq(proxy.totalAssets(), 1000e6);
    }

    // -----------------------------------------------------------------------
    // 2. Strategy management
    // -----------------------------------------------------------------------
    function test_setStrategy_works() public {
        address newAsset = makeAddr("newAsset");
        IStrategy newStrategy = IStrategy(address(new MockStrategy(newAsset)));
        vm.prank(owner);
        proxy.setStrategy(newStrategy);
        assertEq(address(proxy.strategy()), address(newStrategy));
    }

    function test_setStrategy_onlyOwner() public {
        address newAsset = makeAddr("newAsset");
        IStrategy newStrategy = IStrategy(address(new MockStrategy(newAsset)));

        vm.expectRevert();
        vm.prank(attacker);
        proxy.setStrategy(newStrategy);
    }

    function test_setStrategy_zeroAddressReverts() public {
        IStrategy newStrategy = IStrategy(address(0));

        vm.expectRevert();
        vm.prank(owner);
        proxy.setStrategy(newStrategy);
    }

    // -----------------------------------------------------------------------
    // 3. Invest
    // -----------------------------------------------------------------------

    function test_invest_transfersFundsToStrategy() public {
        vm.prank(toko);
        proxy.deposit(1000e6, toko);

        uint256 proxyBalanceBefore = usdc.balanceOf(address(proxy));
        uint256 investAmount = 500e6;

        vm.prank(owner);
        proxy.invest(investAmount);

        assertEq(strategy.totalAssets(), investAmount);
        assertLt(usdc.balanceOf(address(proxy)), proxyBalanceBefore);
    }

    function test_invest_noStrategyReverts() public {
        vm.startPrank(owner);
        UsdcVaultV1 implV1 = new UsdcVaultV1();
        bytes memory data =
            abi.encodeWithSelector(UsdcVaultV1.initialize.selector, IERC20(address(usdc)), "Vault", "vUSDC");
        ERC1967Proxy freshProxy = new ERC1967Proxy(address(implV1), data);
        UsdcVaultV2 implV2 = new UsdcVaultV2();
        UsdcVaultV1(address(freshProxy)).upgradeToAndCall(address(implV2), "");
        UsdcVaultV2 vaultNoStrategy = UsdcVaultV2(address(freshProxy));
        vm.stopPrank();

        vm.expectRevert();
        vm.prank(owner);
        vaultNoStrategy.invest(100e6);
    }

    // -----------------------------------------------------------------------
    // 4. Withdraw with strategy
    // -----------------------------------------------------------------------

    function test_loss_minor() public {
        _runLossScenario(900e6, 10e6); // 1% loss
    }

    function test_loss_major() public {
        _runLossScenario(900e6, 450e6); // 50% loss
    }

    function test_loss_totalStrategyWipeout() public {
        _runLossScenario(1000e6, 1000e6); // 100% strategy loss
    }

    function test_simulateYield() public {
        uint256 assetsBefore = proxy.totalAssets();
        uint256 profit = 500e6;

        vm.startPrank(owner);
        proxy.invest(800e6);
        strategy.simulateYield(profit);
        vm.stopPrank();

        assertEq(proxy.totalAssets(), assetsBefore + profit);
        assertGt(proxy.sharePrice(), 1e18);
    }

    function test_withdraw_handlesStrategyLoss() public {
        uint256 investAmount = 900e6;
        uint256 lossAmount = 180e6;

        vm.prank(owner);
        proxy.invest(investAmount);

        vm.prank(owner);
        strategy.simulateLoss(lossAmount);

        assertEq(proxy.totalAssets(), 820e6);

        uint256 available = proxy.maxWithdraw(toko);
        uint256 tokoBalanceBefore = usdc.balanceOf(toko); // ← capture here

        vm.prank(toko);
        proxy.withdraw(available, toko, toko);

        assertEq(usdc.balanceOf(toko), tokoBalanceBefore + available); // ✅
        assertLt(available, 1000e6); // ✅ less than deposited due to loss
    }

    // -----------------------------------------------------------------------
    // 5. totalAssets includes strategy
    // -----------------------------------------------------------------------
    function test_totalAssets_includesStrategy() public {
        uint256 depositAmount = 1000e6;
        uint256 investAmount = 500e6;

        vm.prank(owner);
        proxy.invest(500e6);

        assertEq(strategy.totalAssets(), investAmount);
        assertEq(proxy.totalAssets(), depositAmount);
    }

    function test_mockStrategy_lossExceedsBalance() public {
        vm.prank(owner);
        strategy.simulateLoss(999999e6); // loss > balance → _totalAssets = 0

        assertEq(strategy.totalAssets(), 0);
    }

    function test_mockStrategy_withdrawExceedsBalance() public {
        // withdraw more than strategy has → returns _totalAssets
        uint256 returned = strategy.withdraw(999999e6);
        assertEq(returned, 0);
    }
}
