// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {UsdcVaultV1} from "../../src//upgradeable/UsdcVaultV1.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployUsdcVaultV1 is Script {
    function run() external returns (UsdcVaultV1 proxy, UsdcVaultV1 implementation, HelperConfig helperConfig) {
        // 1. get usdc address from HelperConfig
        helperConfig = new HelperConfig();
        address usdcAddress = helperConfig.activeNetworkConfig();

        vm.startBroadcast();
        // 2. deploy implementation — logic only, no state
        implementation = new UsdcVaultV1();

        // 3. encode initialize calldata — this runs on proxy deployment
        bytes memory data = abi.encodeWithSelector(
            UsdcVaultV1.initialize.selector, IERC20(usdcAddress), "Upgradeable USDC Vault", "uUSDC"
        );
        // 4. deploy proxy — users always interact with this address
        //    proxy stores all state, delegates logic to implementation
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), data);

        vm.stopBroadcast();

        // wrap proxy address in UsdcVaultV1 interface so caller can use it directly
        proxy = UsdcVaultV1(address(proxyContract));
    }
}
