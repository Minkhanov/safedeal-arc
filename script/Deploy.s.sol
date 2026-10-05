// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SafeDeal, IStablecoin} from "../src/SafeDeal.sol";

/// @notice Deploys SafeDeal against Arc's native USDC and EURC ERC-20 interfaces.
///         forge script script/Deploy.s.sol:Deploy --rpc-url arc --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    /// Same address on Arc mainnet (5042) and Arc testnet (5042002).
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant EURC_MAINNET = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address internal constant EURC_TESTNET = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    function run() external returns (SafeDeal sd) {
        require(block.chainid == 5042 || block.chainid == 5042002, "Deploy: not an Arc network, use DeployLocal");
        address eurc = block.chainid == 5042 ? EURC_MAINNET : EURC_TESTNET;
        vm.startBroadcast();
        sd = new SafeDeal(IStablecoin(ARC_USDC), IStablecoin(eurc));
        vm.stopBroadcast();
        console2.log("SafeDeal deployed at:", address(sd));
        console2.log("USDC (ERC-20 interface):", ARC_USDC);
        console2.log("EURC:", eurc);
        console2.log("Chain id:", block.chainid);
    }
}
