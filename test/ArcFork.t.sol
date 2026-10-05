// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SafeDeal, IStablecoin} from "../src/SafeDeal.sol";

interface ITokenView {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function version() external view returns (string memory);
    function decimals() external view returns (uint8);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Read-only checks against the real Arc stablecoins. Runs only on a fork:
///         forge test --match-contract ArcFork --fork-url https://rpc.mainnet.arc.io
contract ArcForkTest is Test {
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant EURC_MAINNET = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address internal constant EURC_TESTNET = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    function _onArc() internal view returns (bool) {
        return block.chainid == 5042 || block.chainid == 5042002;
    }

    function _eurc() internal view returns (address) {
        return block.chainid == 5042 ? EURC_MAINNET : EURC_TESTNET;
    }

    function _checkDomain(address token, string memory expectedName) internal view {
        ITokenView t = ITokenView(token);
        assertEq(t.decimals(), 6, "ERC-20 interface uses 6 decimals");
        assertEq(t.name(), expectedName);
        assertEq(t.version(), "2");
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(expectedName)),
                keccak256("2"),
                block.chainid,
                token
            )
        );
        assertEq(t.DOMAIN_SEPARATOR(), expected, "permit domain the web app signs with");
    }

    /// The web app signs permits with {name, version "2", chainId, token}; both tokens must match.
    function test_PermitDomainsMatchWebApp() public {
        if (!_onArc()) vm.skip(true);
        _checkDomain(ARC_USDC, "USDC");
        _checkDomain(_eurc(), "EURC");
    }

    function test_DeploysAgainstRealStablecoins() public {
        if (!_onArc()) vm.skip(true);
        SafeDeal sd = new SafeDeal(IStablecoin(ARC_USDC), IStablecoin(_eurc()));
        assertTrue(sd.isSupportedToken(ARC_USDC));
        assertTrue(sd.isSupportedToken(_eurc()));
    }
}
