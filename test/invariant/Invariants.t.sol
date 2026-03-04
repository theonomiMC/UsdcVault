// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {UsdcVault} from "../../src/UsdcVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {UsdcInvariantHandler} from "./Handler.t.sol";

contract UsdcVaultInvariants is StdInvariant, Test {
    UsdcVault public vault;
    MockERC20 public usdc;
    UsdcInvariantHandler public handler;

    address[] internal actors;
    address internal feeRecipient;

    function setUp() public {
        usdc = new MockERC20("Mock USD", "mUSDC", 6);

        // IMPORTANT: vault owner becomes address(this)
        vault = new UsdcVault(usdc, "Vault USDC", "vUSDC");
        feeRecipient = vault.owner();

        actors = new address[](3);
        actors[0] = address(0x1);
        actors[1] = address(0x2);
        actors[2] = address(0x3);

        handler = new UsdcInvariantHandler(vault, actors, feeRecipient);
        targetContract(address(handler));
    }

    /// 1) totalAssets must always equal token balance (since you override totalAssets)
    function invariant_totalAssets_matches_balance() public view {
        assertEq(
            vault.totalAssets() + vault.getAccumulatedFees(),
            usdc.balanceOf(address(vault)),
            "Total assets + fees must equal vault token balance"
        );
    }

    function invariant_totalSupply_matches_balances() public view {
        uint256 sum = vault.balanceOf(feeRecipient);
        for (uint256 i; i < actors.length; i++) {
            sum += vault.balanceOf(actors[i]);
        }
        assertEq(vault.totalSupply(), sum, "totalSupply must equal sum of all share balances");
    }

    function invariant_hwm_never_decreases() public view {
        assertGe(vault.highWaterMark(), 1e18, "HWM must never drop below initial value");
    }

    function invariant_share_price_positive() public view {
        if (vault.totalSupply() > 0) {
            assertGt(vault.sharePrice(), 0, "share price must never be zero with active supply");
        }
    }
}
