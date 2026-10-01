// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SwapCounterToken
/// @notice The launch token deployed beside `SwapCounterHook`: a plain, fixed-supply ERC-20.
/// @dev No constructor arguments, 18 decimals, exactly 1,000,000,000 tokens minted once to the
/// deployer. There is no mint, burn-by-admin, owner, pause, blocklist, fee or upgrade path; the
/// contract is OpenZeppelin's ERC20 and nothing else. The launch factory refuses any other shape.
contract SwapCounterToken is ERC20 {
    /// @notice The whole supply, minted once in the constructor.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("Swap Counter", "SWPC") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
