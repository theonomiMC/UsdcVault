// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcVaultV2} from "../../src/upgradeable/UsdcVaultV2.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract StrategyInvariantHandler is Test {
    UsdcVaultV2 public vault;
    MockERC20 public usdc;
    MockStrategy public strategy; // CURRENT strategy
    MockStrategy[] public oldStrategies;

    address[] public actors;
    address public feeRecipient;

    uint256 public ghost_unauthorizedSuccess;
    uint256 public ghost_allowanceMismatch;
    uint256 public ghost_redeemAllFailed;
    uint256 public ghost_roundTripProfit;
    uint256 public ghost_swapAssetsDelta;
    uint256 public ghost_pausedActionSucceeded;
    uint256 public ghost_bystanderLoss;
    uint256 public ghost_claimMismatch;
    uint256 public ghost_withdrawMismatch;
    uint256 public ghost_redeemOverpay; // redeem paid MORE than previewRedeem (fee under-charge)

    // ---- informational ----
    uint256 public info_zeroShareDepositSkipped;
    uint256 public info_previewOverstated; // known L-02
    uint256 public info_roundTripExitReverted;
    uint256 public info_swapReverted;
    uint256 public info_dustSkipped;

    uint256 public maxHwmSeen;
    mapping(bytes4 => uint256) public calls;

    uint256 internal constant TOL = 3; // asset-wei rounding tolerance for bystander check

    modifier track() {
        calls[msg.sig]++;
        _;
        uint256 h = vault.highWaterMark();
        if (h > maxHwmSeen) maxHwmSeen = h;
    }

    constructor(UsdcVaultV2 _vault, MockStrategy _strategy, address[] memory _actors, address _feeRecipient) {
        vault = _vault;
        strategy = _strategy;
        actors = _actors;
        feeRecipient = _feeRecipient;
        usdc = MockERC20(address(vault.asset()));
        maxHwmSeen = vault.highWaterMark();

        for (uint256 i; i < actors.length; i++) {
            usdc.mint(actors[i], 10_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    // -------------------------------------------------------------- views
    function oldStrategiesLength() external view returns (uint256) {
        return oldStrategies.length;
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function getActor(uint256 seed) public view returns (address) {
        return actors[seed % actors.length];
    }

    // -------------------------------------------------------------- helpers
    function _topUp(address a, uint256 min) internal {
        if (usdc.balanceOf(a) < min) usdc.mint(a, 10_000e6);
    }

    function _other(address a, uint256 seed) internal view returns (address) {
        address b = actors[(seed >> 8) % actors.length];
        if (b == a) b = actors[(seed + 1) % actors.length];
        return b;
    }

    function _value(address who) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(who));
    }

    /// Bystander check is only meaningful when no performance fee is pending (a pending fee legitimately
    /// dilutes everyone when it crystallises).
    function _noPendingFee() internal view returns (bool) {
        return vault.totalSupply() == 0 || vault.sharePrice() <= vault.highWaterMark();
    }

    function _bystanderCheck(address bystander, uint256 before, bool armed) internal {
        if (!armed) return;
        uint256 afterV = _value(bystander);
        if (afterV + TOL < before) ghost_bystanderLoss++;
    }

    // -------------------------------------------------------------- user actions
    function funcDeposit(uint256 amount, uint256 seed) public track {
        address a = getActor(seed);
        _topUp(a, 1e6);
        amount = bound(amount, 1e6, usdc.balanceOf(a));
        if (vault.previewDeposit(amount) == 0) {
            info_zeroShareDepositSkipped++;
            return;
        }
        address by = _other(a, seed);
        bool armed = _noPendingFee();
        uint256 before = _value(by);

        vm.prank(a);
        vault.deposit(amount, a);
        _bystanderCheck(by, before, armed);
    }

    function funcMint(uint256 shares, uint256 seed) public track {
        address a = getActor(seed);
        shares = bound(shares, 1e3, 1e12);
        uint256 maxMint = vault.maxMint(a);
        if (maxMint == 0) return;
        if (shares > maxMint) shares = maxMint;
        uint256 need = vault.previewMint(shares);
        _topUp(a, need);
        if (need == 0 || need > usdc.balanceOf(a)) return;

        address by = _other(a, seed);
        bool armed = _noPendingFee();
        uint256 before = _value(by);

        vm.prank(a);
        vault.mint(shares, a);
        _bystanderCheck(by, before, armed);
    }

    function funcWithdraw(uint256 amount, uint256 seed) public track {
        address a = getActor(seed);
        uint256 max = vault.maxWithdraw(a);
        if (max < 1e6) return;
        amount = bound(amount, 1e6, max);

        address by = _other(a, seed);
        bool armed = _noPendingFee();
        uint256 before = _value(by);
        uint256 balBefore = usdc.balanceOf(a);

        vm.prank(a);
        try vault.withdraw(amount, a, a) {
            if (usdc.balanceOf(a) != balBefore + amount) ghost_withdrawMismatch++;
            _bystanderCheck(by, before, armed);
        } catch {} // can revert with ExceededMaxWithdraw when a fee crystallises first (L-02): benign
    }

    function funcRedeem(uint256 shares, uint256 seed) public track {
        address a = getActor(seed);
        uint256 max = vault.maxRedeem(a);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        uint256 expected = vault.previewRedeem(shares);
        if (expected == 0) {
            info_dustSkipped++;
            return;
        }

        address by = _other(a, seed);
        bool armed = _noPendingFee();
        uint256 before = _value(by);
        uint256 balBefore = usdc.balanceOf(a);

        vm.prank(a);
        vault.redeem(shares, a, a);

        uint256 got = usdc.balanceOf(a) - balBefore;
        if (got > expected) ghost_redeemOverpay++;
        if (got < expected) info_previewOverstated++;
        _bystanderCheck(by, before, armed);
    }

    /// M-03: redeeming the whole balance must always work.
    function funcRedeemAll(uint256 seed) public track {
        address a = getActor(seed);
        uint256 sh = vault.balanceOf(a);
        if (sh == 0) return;
        if (vault.previewRedeem(sh) == 0) {
            info_dustSkipped++;
            return;
        }
        vm.prank(a);
        try vault.redeem(sh, a, a) {
            if (vault.balanceOf(a) != 0) ghost_redeemAllFailed++;
        } catch {
            ghost_redeemAllFailed++;
        }
    }

    /// C-01: a third party can NOT move funds without allowance; WITH allowance it works and the allowance
    /// is reduced by exactly the shares burned.
    function funcThirdParty(uint256 amount, uint256 seed) public track {
        address owner_ = getActor(seed);
        address spender = _other(owner_, seed);
        uint256 bal = vault.balanceOf(owner_);
        if (bal == 0) return;
        bool useRedeem = (seed >> 16) % 2 == 0;
        bool withAllowance = (seed >> 24) % 2 == 0;

        // reset allowance
        vm.prank(owner_);
        vault.approve(spender, withAllowance ? bal : 0);

        uint256 ownerSharesBefore = vault.balanceOf(owner_);
        uint256 allowanceBefore = vault.allowance(owner_, spender);
        uint256 spenderUsdcBefore = usdc.balanceOf(spender);

        if (useRedeem) {
            uint256 shares = bound(amount, 1, ownerSharesBefore);
            if (vault.previewRedeem(shares) == 0) return;
            vm.prank(spender);
            try vault.redeem(shares, spender, owner_) {
                _thirdPartyOutcome(withAllowance, owner_, spender, ownerSharesBefore, allowanceBefore);
            } catch {}
        } else {
            uint256 max = vault.maxWithdraw(owner_);
            if (max < 1e6) return;
            uint256 want = bound(amount, 1e6, max);
            vm.prank(spender);
            try vault.withdraw(want, spender, owner_) {
                _thirdPartyOutcome(withAllowance, owner_, spender, ownerSharesBefore, allowanceBefore);
                if (withAllowance && usdc.balanceOf(spender) != spenderUsdcBefore + want) ghost_withdrawMismatch++;
            } catch {}
        }
    }

    function _thirdPartyOutcome(
        bool withAllowance,
        address owner_,
        address spender,
        uint256 sharesBefore,
        uint256 allowanceBefore
    ) internal {
        if (!withAllowance) {
            ghost_unauthorizedSuccess++; // succeeded with ZERO allowance
            return;
        }
        uint256 burned = sharesBefore - vault.balanceOf(owner_);
        uint256 spent = allowanceBefore - vault.allowance(owner_, spender);
        if (burned != spent) ghost_allowanceMismatch++;
    }

    /// Round trip must never be profitable.
    function funcRoundTrip(uint256 amount, uint256 seed) public track {
        address a = getActor(seed);
        _topUp(a, 1e6);
        amount = bound(amount, 1e6, _min(usdc.balanceOf(a), 1_000e6));
        if (vault.previewDeposit(amount) == 0) return;

        vm.prank(a);
        uint256 minted = vault.deposit(amount, a);
        vm.prank(a);
        try vault.redeem(minted, a, a) returns (uint256 got) {
            if (got > amount) ghost_roundTripProfit += got - amount;
        } catch {
            info_roundTripExitReverted++; // dust position cannot exit (assets == 0) - informational
        }
    }

    // -------------------------------------------------------------- owner / environment actions
    function funcInvest(uint256 amount) public track {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 fees = vault.getAccumulatedFees();
        if (bal <= fees) return;
        amount = bound(amount, 1, bal - fees);
        vm.prank(feeRecipient);
        vault.invest(amount);
    }

    function funcSimulateYield(uint256 amount) public track {
        // keep the share price in a realistic band (<= 20x). Unbounded compounding drives price to ~1e9x
        // where virtual-share rounding dominates and unrelated rounding effects swamp the properties under test.
        if (vault.totalSupply() > 0 && vault.sharePrice() > 20e18) return;
        uint256 ta = vault.totalAssets();
        amount = bound(amount, 1, _max(1e6, ta / 2));
        usdc.mint(address(strategy), amount); // yield is backed by real tokens
        vm.prank(feeRecipient);
        strategy.simulateYield(amount);
    }

    function funcSimulateLoss(uint256 amount) public track {
        uint256 s = strategy.totalAssets();
        if (s == 0) return;
        amount = bound(amount, 1, s);
        vm.prank(feeRecipient);
        strategy.simulateLoss(amount);
    }

    function funcDonate(uint256 amount) public track {
        usdc.mint(address(vault), bound(amount, 1, 1_000e6));
    }

    /// M-01: swapping strategy must not change totalAssets and must not orphan funds.
    function funcSetStrategy(uint256 seed) public track {
        if (seed % 4 != 0) return;
        MockStrategy old = strategy;
        uint256 taBefore = vault.totalAssets();

        vm.startPrank(feeRecipient);
        MockStrategy fresh = new MockStrategy(address(usdc));
        try vault.setStrategy(IStrategy(address(fresh))) {
            vm.stopPrank();
            if (vault.totalAssets() != taBefore) ghost_swapAssetsDelta++;
            oldStrategies.push(old);
            strategy = fresh;
        } catch {
            vm.stopPrank();
            info_swapReverted++;
        }
    }

    function funcClaimFees(uint256 seed) public track {
        if ((seed % 3) != 0) return;
        uint256 fees = vault.getAccumulatedFees();
        if (fees == 0) return;
        uint256 ownerBefore = usdc.balanceOf(feeRecipient);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.prank(feeRecipient);
        vault.claimFees();

        if (
            vault.getAccumulatedFees() != 0 || usdc.balanceOf(feeRecipient) != ownerBefore + fees
                || usdc.balanceOf(address(vault)) != vaultBefore - fees
        ) ghost_claimMismatch++;
    }

    /// While paused, none of the four user entry points may succeed.
    function funcPauseCheck(uint256 seed) public track {
        if (seed % 10 != 0) return;
        address a = getActor(seed);
        _topUp(a, 2e6);

        vm.prank(feeRecipient);
        vault.pause();

        vm.startPrank(a);
        try vault.deposit(1e6, a) {
            ghost_pausedActionSucceeded++;
        } catch {}
        try vault.mint(1e3, a) {
            ghost_pausedActionSucceeded++;
        } catch {}
        try vault.withdraw(1, a, a) {
            ghost_pausedActionSucceeded++;
        } catch {}
        try vault.redeem(1, a, a) {
            ghost_pausedActionSucceeded++;
        } catch {}
        vm.stopPrank();

        vm.prank(feeRecipient);
        vault.unpause();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
