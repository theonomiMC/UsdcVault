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

        // 5. tell Foundry to call handler functions during invariant runs
        targetContract(address(handler));
    }

    // invariant 1 — accounting: assets split between vault and strategy
    function invariant_totalAssets_accounting() public view {
        assertEq(
            vault.totalAssets() + vault.getAccumulatedFees(),
            usdc.balanceOf(address(vault)) + strategy.totalAssets(),
            "Accounting invariant violated: token tracking is inconsistent"
        );
    }

    // invariant 2 — HWM never decreases
    function invariant_hwm_neverDecreases() public view {
        assertGe(vault.highWaterMark(), 1e18);
    }

    // invariant 3 — sharePrice positive when supply exists
    function invariant_sharePrice_positive() public view {
        assertGe(vault.sharePrice(), 0);
    }
}
