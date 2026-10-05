// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockStablecoin} from "./MockStablecoin.sol";

/// @notice TEST ONLY. `transferFrom` works normally (so deals can be funded) but `transfer` burns all
///         the gas it is given. Used to prove that SafeDeal reverts instead of deferring a payout when
///         the transfer ran out of gas.
contract GasBurnerToken is MockStablecoin {
    bool public burn;

    constructor() MockStablecoin("USDC") {}

    function setBurn(bool on) external {
        burn = on;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        if (burn) {
            uint256 x;
            while (true) {
                x++;
            }
        }
        _move(msg.sender, to, value);
        return true;
    }
}
