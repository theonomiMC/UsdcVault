// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {UsdcVaultV1} from "../../../src/upgradeable/UsdcVaultV1.sol";
import {UsdcVaultV2} from "../../../src/upgradeable/UsdcVaultV2.sol";
import {IStrategy} from "../../../src/interfaces/IStrategy.sol";
import {MockStrategy} from "../../mocks/MockStrategy.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StrategyInvariantHandler} from "../HandlerV2.t.sol";

contract UsdcVaultV2Invariants is StdInvariant, Test {
    UsdcVaultV2 public vault;
    MockStrategy public strategy;
    MockERC20 public usdc;
    StrategyInvariantHandler public handler;

    address[] internal actors;
    address public owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockERC20("Mock USD", "mUSDC", 6);

        // 1. deploy V1 + proxy
        vm.startPrank(owner);
        UsdcVaultV1 implV1 = new UsdcVaultV1();
        bytes memory data = abi.encodeWithSelector(
            UsdcVaultV1.initialize.selector, IERC20(address(usdc)), "Upgradeable USDC Vault", "uUSDC"
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implV1), data);
        // 2. upgrade to V2
        UsdcVaultV2 implV2 = new UsdcVaultV2();
        UsdcVaultV1(address(proxy)).upgradeToAndCall(address(implV2), "");
        vault = UsdcVaultV2(address(proxy));

        // 3. deploy strategy and set it
        strategy = new MockStrategy(address(usdc));
        vault.setStrategy(IStrategy(address(strategy)));
        vm.stopPrank();

        actors = new address[](3);
        actors[0] = address(0x1);
        actors[1] = address(0x2);
        actors[2] = address(0x3);

        handler = new StrategyInvariantHandler(vault, strategy, actors, owner);
        targetContract(address(handler));
    }

    // ===================================================================== state invariants

    /// accounting: depositor assets + fees == idle USDC + CURRENT strategy assets
    function invariant_totalAssets_accounting() public view {
        MockStrategy cur = handler.strategy();
        assertEq(
            vault.totalAssets() + vault.getAccumulatedFees(),
            usdc.balanceOf(address(vault)) + cur.totalAssets(),
            "accounting: token tracking is inconsistent"
        );
    }

    /// fees are always physically in the vault (invest() must never touch them)
    function invariant_fees_areBacked() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.getAccumulatedFees(), "fees not backed by idle USDC");
    }

    /// no shares appear or vanish: tracked holders + owner (fee shares) == totalSupply
    function invariant_sharesConserved() public view {
        uint256 sum = vault.balanceOf(owner);
        for (uint256 i; i < handler.actorsLength(); i++) {
            sum += vault.balanceOf(handler.getActor(i));
        }
        assertEq(sum, vault.totalSupply(), "share supply != sum of holders");
    }

    /// vault can never owe more than it holds
    function invariant_solvent() public view {
        assertLe(vault.convertToAssets(vault.totalSupply()), vault.totalAssets(), "claims exceed assets");
    }

    /// high-water mark never decreases (replaces the old `>= 1e18` check)
    function invariant_hwm_neverDecreases() public view {
        assertGe(vault.highWaterMark(), handler.maxHwmSeen(), "HWM decreased");
        assertGe(vault.highWaterMark(), 1e18, "HWM below initial");
    }

    /// share price is positive whenever there is supply and assets (replaces the `>= 0` tautology)
    function invariant_sharePrice_positive() public view {
        if (vault.totalSupply() > 0 && vault.totalAssets() > 0) {
            assertGt(vault.sharePrice(), 0, "share price is zero with supply and assets");
        }
    }

    /// M-01: a swapped-out strategy must hold nothing (no orphaned funds)
    function invariant_noOrphanedStrategyFunds() public view {
        for (uint256 i; i < handler.oldStrategiesLength(); i++) {
            MockStrategy s = handler.oldStrategies(i);
            assertEq(s.totalAssets(), 0, "old strategy still reports assets");
            assertEq(usdc.balanceOf(address(s)), 0, "old strategy still holds USDC");
        }
    }

    // ===================================================================== behavioural invariants (ghost counters)

    function invariant_noUnauthorizedWithdraw() public view {
        assertEq(handler.ghost_unauthorizedSuccess(), 0, "C-01: third party moved funds without allowance");
    }

    function invariant_allowanceSpentEqualsSharesBurned() public view {
        assertEq(handler.ghost_allowanceMismatch(), 0, "allowance spent != shares burned");
    }

    function invariant_redeemAllAlwaysWorks() public view {
        assertEq(handler.ghost_redeemAllFailed(), 0, "M-03: redeem(maxRedeem) failed");
    }

    function invariant_roundTripNeverProfitable() public view {
        assertEq(handler.ghost_roundTripProfit(), 0, "deposit->redeem produced profit");
    }

    function invariant_strategySwapKeepsTotalAssets() public view {
        assertEq(handler.ghost_swapAssetsDelta(), 0, "M-01: setStrategy changed totalAssets");
    }

    function invariant_pauseBlocksUserActions() public view {
        assertEq(handler.ghost_pausedActionSucceeded(), 0, "user action succeeded while paused");
    }

    function invariant_noValueExtractedFromBystanders() public view {
        assertEq(handler.ghost_bystanderLoss(), 0, "an action reduced a bystander's value");
    }

    function invariant_withdrawPaysExactAmount() public view {
        assertEq(handler.ghost_withdrawMismatch(), 0, "withdraw(x) did not pay exactly x");
    }

    function invariant_redeemNeverPaysMoreThanPreview() public view {
        assertEq(handler.ghost_redeemOverpay(), 0, "redeem paid more than previewRedeem (fee under-charge)");
    }

    function invariant_claimFeesExact() public view {
        assertEq(handler.ghost_claimMismatch(), 0, "claimFees moved wrong amount");
    }
}
