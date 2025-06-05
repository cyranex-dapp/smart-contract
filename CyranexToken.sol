// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// OpenZeppelin ERC20/Ownable
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// --- CNX Token ---
contract CyranexToken is ERC20, Ownable {
    constructor(
        address initialOwner
    ) ERC20("CYRANEX", "CNX") Ownable(initialOwner) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
