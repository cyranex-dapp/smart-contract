// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

struct Deposit {
    uint256 amount;
    uint256 startTime;
    uint256 claimedROI;
    bool closed;
    uint256 lastRoiClaim;
}

struct User {
    bool registered;
    address referrer;
    address[] directList;
    Deposit[] deposits;
    uint256 registrationTime;
    uint256 withdrawableBalance;
    uint256 lastWithdrawTime;
    uint256 totalWithdrawn;
    uint256 totalTopup;
    uint256 totalReferralBonusEarned;
    uint256 totalTeamRoiEarned;
    uint256 totalRoiEarned;
    // Fast Start Bonus
    bool fastStartClaimed;
    uint256 fastStartBonus;
    uint256 fastStartEligibleDirects;
    uint256 fastStartClaimTime;
}
