// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {UsdcVaultV1} from "../../src/upgradeable/UsdcVaultV1.sol";
import {UsdcVaultV2} from "../../src/upgradeable/UsdcVaultV2.sol";

contract DeployUpgradeToV2 is Script {
    function run() external returns (UsdcVaultV2) {
        address proxy = vm.envAddress("VAULT_V1_PROXY");

        vm.startBroadcast();

        // 1. deploy new implementation
        UsdcVaultV2 implV2 = new UsdcVaultV2();

        // 2. upgrade proxy to point to new implementation
        UsdcVaultV1(proxy).upgradeToAndCall(address(implV2), "");

        vm.stopBroadcast();

        // return proxy wrapped as V2 — same address, new logic
        return UsdcVaultV2(proxy);
    }
}
