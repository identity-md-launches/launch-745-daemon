// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {DaemonToken} from "../src/DaemonToken.sol";

/// @title DaemonToken deploy script
/// @notice Deploys `DaemonToken`. The token has no constructor arguments and no post-deploy
///         configuration, so the only deployment parameter is the deployer itself: whoever sends
///         the creation transaction receives the entire supply.
/// @dev Under the IMD launch flow the ProjectFactory deploys the token through CREATE2 and the
///      factory is therefore `msg.sender` in the constructor. This script exists for reviewable,
///      stand-alone deployments (local anvil, testnets, manual review). `deploy()` is pure
///      deployment logic that the tests call directly; `run()` only wraps it in a broadcast.
///      This repository never holds keys and this script never reads the environment.
contract DeployDaemonToken is Script {
    /// @notice Deploys a fresh `DaemonToken`. The caller of this function's enclosing transaction
    ///         (the broadcaster under `run()`, the test contract under tests) receives the supply.
    function deploy() public returns (DaemonToken token) {
        token = new DaemonToken();
    }

    /// @notice Broadcast entry point: `forge script script/DeployDaemonToken.s.sol --broadcast ...`.
    ///         The broadcaster is chosen by the forge CLI flags (`--private-key`, `--ledger`,
    ///         `--account`); nothing here reads a key or an environment variable.
    function run() external returns (DaemonToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
