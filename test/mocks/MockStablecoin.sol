// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice LOCAL DEVELOPMENT ONLY. Mimics the parts of Arc's USDC/EURC ERC-20 interfaces that
///         SafeDeal uses: 6 decimals, FiatToken-style revert strings, a blocklist and EIP-2612
///         permit with the same EIP-712 domain (name = symbol, version "2"). Anyone can mint and
///         anyone can toggle the blocklist — never deploy this anywhere but a local devnet.
contract MockStablecoin {
    string public name;
    string public symbol;
    string public constant version = "2";
    uint8 public constant decimals = 6;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;
    mapping(address => bool) public isBlacklisted;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _symbol) {
        name = _symbol;
        symbol = _symbol;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 value) external {
        totalSupply += value;
        balanceOf[to] += value;
        emit Transfer(address(0), to, value);
    }

    function setBlacklisted(address account, bool blocked) external {
        isBlacklisted[account] = blocked;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _notBlacklisted(msg.sender);
        _notBlacklisted(spender);
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external virtual returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _notBlacklisted(msg.sender);
        require(value <= allowance[from][msg.sender], "ERC20: transfer amount exceeds allowance");
        allowance[from][msg.sender] -= value;
        _move(from, to, value);
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        require(deadline >= block.timestamp, "FiatTokenV2: permit is expired");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == owner, "EIP2612: invalid signature");
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _notBlacklisted(address account) private view {
        require(!isBlacklisted[account], "Blacklistable: account is blacklisted");
    }

    function _move(address from, address to, uint256 value) internal {
        _notBlacklisted(from);
        _notBlacklisted(to);
        require(to != address(0), "ERC20: transfer to the zero address");
        require(value <= balanceOf[from], "ERC20: transfer amount exceeds balance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
    }
}
