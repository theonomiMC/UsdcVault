// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcVaultV1} from "../../src/upgradeable/UsdcVaultV1.sol";
import {
    UsdcVaultV2,
    UsdcVaultV2_WrongAsset,
    UsdcVaultV2_StrategyNotEmpty,
    UsdcVault_InvalidGross,
    UsdcVaultV2_InvestExceedsAvailable,
    UsdcVaultV2_InsufficientLiquidity
} from "../../src/upgradeable/UsdcVaultV2.sol";
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
        MockStrategy nextStrategy = new MockStrategy(address(usdc));
        vm.prank(owner);
        proxy.invest(500e6);
        uint256 assets = proxy.totalAssets();
        uint256 idle = usdc.balanceOf(address(proxy));

        vm.prank(owner);
        proxy.setStrategy(nextStrategy);

        assertEq(address(proxy.strategy()), address(nextStrategy));
        assertEq(strategy.totalAssets(), 0);
        assertEq(usdc.balanceOf(address(strategy)), 0);
        assertEq(usdc.balanceOf(address(proxy)), idle + 500e6);
        assertEq(proxy.totalAssets(), assets);
    }

    function test_setStrategy_rejectsWrongAsset() public {
        MockStrategy wrongStrategy = new MockStrategy(makeAddr("wrongAsset"));
        vm.expectRevert(UsdcVaultV2_WrongAsset.selector);
        vm.prank(owner);
        proxy.setStrategy(wrongStrategy);
        assertEq(address(proxy.strategy()), address(strategy));
    }

    function test_setStrategy_rejectsNonemptyOldStrategy() public {
        MockStrategy nextStrategy = new MockStrategy(address(usdc));
        vm.prank(owner);
        proxy.invest(500e6);
        vm.mockCall(address(strategy), abi.encodeCall(IStrategy.withdrawAll, ()), abi.encode(uint256(0)));
        vm.expectRevert(UsdcVaultV2_StrategyNotEmpty.selector);
        vm.prank(owner);
        proxy.setStrategy(nextStrategy);
        assertEq(address(proxy.strategy()), address(strategy));
        assertEq(strategy.totalAssets(), 500e6);
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

        assertEq(usdc.balanceOf(toko), tokoBalanceBefore + available);
        assertLt(available, 1000e6);
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

    function test_V2_redeemDustRevertsInvalidGross() public {
        uint256 dustShares = 1;

        assertEq(proxy.previewRedeem(dustShares), 0);

        uint256 sharesBefore = proxy.balanceOf(toko);
        uint256 feesBefore = proxy.getAccumulatedFees();

        vm.expectRevert(UsdcVault_InvalidGross.selector);
        vm.prank(toko);
        proxy.redeem(dustShares, toko, toko);

        assertEq(proxy.balanceOf(toko), sharesBefore);
        assertEq(proxy.getAccumulatedFees(), feesBefore);
    }

    function test_PoC_strategyWithdrawReentrancy() public {
        // 1. Deploy malicious strategy
        ReentrantStrategyContract malicious = new ReentrantStrategyContract(address(usdc), address(proxy));

        // 2. Replace the existing empty strategy
        vm.prank(owner);
        proxy.setStrategy(IStrategy(address(malicious)));

        // 3. Invest 900 USDC
        vm.prank(owner);
        proxy.invest(900e6);

        assertEq(usdc.balanceOf(address(proxy)), 100e6);
        assertEq(malicious.totalAssets(), 900e6);

        // 4. Record balances and shares
        uint256 sharesBefore = proxy.balanceOf(toko);
        uint256 userBalanceBefore = usdc.balanceOf(toko);

        // 5. Withdraw 200 USDC
        // The vault has only 100 USDC idle, so it must
        // call the malicious strategy to cover the shortfall.
        vm.prank(toko);
        proxy.withdraw(200e6, toko, toko);

        // 6. Confirm the malicious callback was executed
        assertEq(malicious.withdrawalCalls(), 1);

        // 7. Verify reentrancy was blocked
        assertFalse(malicious.reentrySucceeded(), "CRITICAL: Reentrant withdrawal succeeded");

        assertEq(
            malicious.reentryError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")), "Unexpected revert reason"
        );

        // 8. Verify the legitimate withdrawal succeeded
        assertEq(usdc.balanceOf(toko), userBalanceBefore + 200e6);

        // 9. Verify shares were burned
        assertLt(proxy.balanceOf(toko), sharesBefore);
    }

    function test_PoC_investExceedsAvailableReverts() public {
        uint256 available = usdc.balanceOf(address(proxy)) - proxy.getAccumulatedFees();

        vm.prank(owner);
        vm.expectRevert(UsdcVaultV2_InvestExceedsAvailable.selector);

        proxy.invest(available + 1);
    }

    function test_PoC_partialStrategyWithdrawalRevertsSafely() public {
        vm.prank(owner);
        proxy.invest(900e6);

        uint256 assets = 200e6;
        uint256 sharesBefore = proxy.balanceOf(toko);
        uint256 feesBefore = proxy.getAccumulatedFees();
        uint256 supplyBefore = proxy.totalSupply();

        // Strategy returns zero instead of the required liquidity.
        vm.mockCall(address(strategy), abi.encodeWithSelector(IStrategy.withdraw.selector), abi.encode(uint256(0)));

        vm.expectRevert(UsdcVaultV2_InsufficientLiquidity.selector);

        vm.prank(toko);
        proxy.withdraw(assets, toko, toko);

        // Accounting must remain unchanged after revert.
        assertEq(proxy.balanceOf(toko), sharesBefore);
        assertEq(proxy.totalSupply(), supplyBefore);
        assertEq(proxy.getAccumulatedFees(), feesBefore);
    }

    function test_PoC_redeemPullsLiquidityFromStrategy() public {
        vm.prank(owner);
        proxy.invest(900e6);

        uint256 shares = proxy.previewWithdraw(200e6);
        uint256 expectedAssets = proxy.previewRedeem(shares);

        uint256 userBalanceBefore = usdc.balanceOf(toko);
        uint256 sharesBefore = proxy.balanceOf(toko);
        uint256 strategyBefore = strategy.totalAssets();

        vm.prank(toko);
        uint256 received = proxy.redeem(shares, toko, toko);

        assertEq(received, expectedAssets);

        assertEq(usdc.balanceOf(toko), userBalanceBefore + received);

        assertEq(proxy.balanceOf(toko), sharesBefore - shares);

        assertLt(strategy.totalAssets(), strategyBefore);
    }
}

contract ReentrantStrategyContract {
    IERC20 public immutable token;
    address public immutable vault;

    bool public reentrySucceeded;
    bytes4 public reentryError;
    uint256 public withdrawalCalls;

    constructor(address _token, address _vault) {
        token = IERC20(_token);
        vault = _vault;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function totalAssets() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function deposit(uint256) external {}

    function withdraw(uint256 amount) external returns (uint256) {
        withdrawalCalls++;

        // Attack: reenter the vault before the outer
        // withdrawal has burned the user's shares.
        (bool success, bytes memory data) =
            vault.call(abi.encodeWithSignature("withdraw(uint256,address,address)", 1e6, address(this), address(this)));

        reentrySucceeded = success;

        if (!success && data.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(data, 32))
            }
            reentryError = selector;
        }

        // Return the liquidity requested by the vault.
        require(token.transfer(msg.sender, amount), "Transfer failed");

        return amount;
    }

    function withdrawAll() external returns (uint256) {
        uint256 balance = token.balanceOf(address(this));
        require(token.transfer(msg.sender, balance), "Transfer failed");
        return balance;
    }
}
