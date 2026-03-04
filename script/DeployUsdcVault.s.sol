// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {UsdcVault} from "../src/UsdcVault.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployUsdcVault is Script {
    function run() external returns (UsdcVault, HelperConfig) {
        // 1. create donfiguration
        HelperConfig helperConfig = new HelperConfig();
        address usdcAddress = helperConfig.activeNetworkConfig();

        // 2. deploy
        vm.startBroadcast();
        UsdcVault vault = new UsdcVault(IERC20(usdcAddress), "USDC Vault", "sUSDC");
        vm.stopBroadcast();

        return (vault, helperConfig);
    }
}
