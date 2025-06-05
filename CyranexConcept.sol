// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./CyranexToken.sol";
import "./Types.sol";
import "./Utils.sol";

contract CyranexConcept is ReentrancyGuard, Ownable, Utils {
    IERC20 public immutable usdt;
    CyranexToken public immutable cnxToken;

    address public admin;

    uint256 public constant MIN_TOPUP = 50 * 1e18;
    uint256 public constant ADMIN_FEE_BP = 500; // 5%
    uint256 public constant MINT_PERCENT_BP = 7000; // 70%
    uint256 public constant INITIAL_TOKEN_PRICE = 4e18;
    uint256 public constant WEEK = 7 days;
    uint256 public constant ROI_WEEKLY_BP = 300; // 3.0%
    uint256 public constant WITHDRAW_CAP_X = 2;
    uint256 public constant FASTSTART_WINDOW = 15 days;
    uint256 public constant FASTSTART_CLAIM_WINDOW = 30 days;

    uint16[20] public roiPercents = [
        1500,
        500,
        500,
        400,
        400,
        300,
        300,
        200,
        200,
        100,
        100,
        100,
        50,
        50,
        50,
        50,
        50,
        50,
        50,
        50
    ]; // 15% to 0.5%

    // --- Events: Use these for all histories ---
    event Registered(
        address indexed user,
        address indexed referrer,
        uint256 time
    );
    event TopUp(
        address indexed user,
        uint256 amount,
        uint256 mintedCNX,
        uint256 time
    );
    event ClaimROI(
        address indexed user,
        uint256 depositAmount,
        uint256 roiAmount,
        uint256 time
    );
    event TeamRoiPaid(
        address indexed upline,
        address indexed downline,
        uint8 level,
        uint256 amount,
        uint256 time
    );
    event DirectReferralBonus(
        address indexed referrer,
        address indexed downline,
        uint256 topupAmount,
        uint256 bonusAmount,
        uint256 time
    );
    event Withdraw(
        address indexed user,
        uint256 usdtAmount,
        uint256 cnxAmount,
        uint256 time
    );
    event FastStartBonusClaimed(
        address indexed user,
        uint256 bonus,
        uint256 directs,
        uint256 time
    );
    event SoldCNXTokens(
        address indexed user,
        uint256 soldCNX,
        uint256 usdtAmount
    );

    receive() external payable {
        revert("Contract does not accept BNB");
    }

    fallback() external payable {
        revert("Contract does not accept BNB");
    }

    constructor(address _usdt, address _admin) Ownable(msg.sender) {
        require(_usdt != address(0), "Invalid USDT");
        require(_admin != address(0), "Invalid admin");
        usdt = IERC20(_usdt);
        admin = _admin;
        cnxToken = new CyranexToken(address(this));
        // Set the root user (contract address as referrer)
        users[msg.sender].registered = true;
        isRegistered[msg.sender] = true;
        users[msg.sender].referrer = address(0);
        users[msg.sender].registrationTime = block.timestamp;
    }

    function register(address referrer) external {
        require(!users[msg.sender].registered, "Already registered");
        require(
            referrer != address(0) && users[referrer].registered,
            "Invalid referrer"
        );
        users[msg.sender].registered = true;
        isRegistered[msg.sender] = true;
        users[msg.sender].referrer = referrer;
        users[msg.sender].registrationTime = block.timestamp;
        users[referrer].directList.push(msg.sender);
        emit Registered(msg.sender, referrer, block.timestamp);
    }

    // --- Top-Up ---
    function topUp(uint256 amount) external onlyRegistered nonReentrant {
        require(
            amount >= MIN_TOPUP && amount % MIN_TOPUP == 0,
            "Invalid top-up amount"
        );
        uint256 currentPrice = getCurrentTokenPrice();
        require(
            usdt.transferFrom(msg.sender, address(this), amount),
            "USDT transfer failed"
        );

        usdt.transfer(admin, (amount * ADMIN_FEE_BP) / 10000);

        uint256 mintCNX = (((amount * MINT_PERCENT_BP) / 10000) * 1e18) /
            currentPrice;
        cnxToken.mint(address(this), mintCNX);

        users[msg.sender].deposits.push(
            Deposit({
                amount: amount,
                startTime: block.timestamp,
                claimedROI: 0,
                closed: false,
                lastRoiClaim: block.timestamp
            })
        );
        users[msg.sender].totalTopup += amount;

        // Direct referral bonus instantly (10%)
        address referrer = users[msg.sender].referrer;
        if (referrer != address(0) && users[referrer].registered) {
            uint256 referralBonus = (amount * 1000) / 10000; // 10%
            users[referrer].withdrawableBalance += referralBonus;
            users[referrer].totalReferralBonusEarned += referralBonus;
            emit DirectReferralBonus(
                referrer,
                msg.sender,
                amount,
                referralBonus,
                block.timestamp
            );
        }

        emit TopUp(msg.sender, amount, mintCNX, block.timestamp);
    }

    // --- Claim ROI (one week per claim per deposit, plus Team ROI) ---
    function claimROI() external onlyRegistered nonReentrant {
        uint256 totalRoi;

        for (uint256 i = 0; i < users[msg.sender].deposits.length; ++i) {
            if (users[msg.sender].deposits[i].closed) continue;
            if (
                block.timestamp <
                users[msg.sender].deposits[i].lastRoiClaim + WEEK
            ) continue;

            //Max ROI = (users[msg.sender].deposits[i].amount * WITHDRAW_CAP_X) - users[msg.sender].deposits[i].claimedROI;
            if (
                (users[msg.sender].deposits[i].amount * WITHDRAW_CAP_X) -
                    users[msg.sender].deposits[i].claimedROI ==
                0
            ) {
                users[msg.sender].deposits[i].closed = true;
                continue;
            }
            uint256 roiForPeriod = (users[msg.sender].deposits[i].amount *
                ROI_WEEKLY_BP) / 10000;
            if (
                roiForPeriod >
                (users[msg.sender].deposits[i].amount * WITHDRAW_CAP_X) -
                    users[msg.sender].deposits[i].claimedROI
            ) {
                roiForPeriod =
                    (users[msg.sender].deposits[i].amount * WITHDRAW_CAP_X) -
                    users[msg.sender].deposits[i].claimedROI;
                users[msg.sender].deposits[i].closed = true;
            }
            users[msg.sender].deposits[i].claimedROI += roiForPeriod;
            users[msg.sender].deposits[i].lastRoiClaim = block.timestamp;
            totalRoi += roiForPeriod;
            emit ClaimROI(
                msg.sender,
                users[msg.sender].deposits[i].amount,
                roiForPeriod,
                block.timestamp
            );
        }

        if (totalRoi > 0) {
            users[msg.sender].withdrawableBalance += totalRoi;
            users[msg.sender].totalRoiEarned += totalRoi;

            // Team ROI Bonus up to 20 levels
            address currentUpline = users[msg.sender].referrer;
            for (
                uint8 level = 0;
                level < 20 && currentUpline != address(0);
                level++
            ) {
                if (getPaidDirectUsers(currentUpline) >= (level + 1) && users[currentUpline].deposits.length > 0) {
                    users[currentUpline].withdrawableBalance += ((totalRoi *
                        roiPercents[level]) / 10000);
                    users[currentUpline].totalTeamRoiEarned += ((totalRoi *
                        roiPercents[level]) / 10000);
                    emit TeamRoiPaid(
                        currentUpline,
                        msg.sender,
                        level + 1,
                        ((totalRoi * roiPercents[level]) / 10000),
                        block.timestamp
                    );
                }
                currentUpline = users[currentUpline].referrer;
            }
        }
    }

    // --- Withdraw earnings (capped at 2x total top-up per user) ---
    function withdraw(uint256 amountUSDT) external onlyRegistered nonReentrant {
        require(
            amountUSDT >= 10 * 1e18 && amountUSDT % (10 * 1e18) == 0,
            "Minimum withdrawal is $10 or multiple of $10."
        );
        // User storage user = users[msg.sender];
        require(
            block.timestamp >= users[msg.sender].lastWithdrawTime + 1 days,
            "Can withdraw once in 24 hours."
        );
        require(
            users[msg.sender].withdrawableBalance >= amountUSDT,
            "Insufficient withdrawable"
        );
        require(
            users[msg.sender].totalWithdrawn + amountUSDT <=
                users[msg.sender].totalTopup * WITHDRAW_CAP_X,
            "2x withdrawal cap reached"
        );

        // uint256 cnxAmount = ((amountUSDT * 1e18) / getCurrentTokenPrice());
        uint256 currentPrice = getCurrentTokenPrice();
        uint256 userAmount = ((amountUSDT * 1e18) / currentPrice) -
            ((((amountUSDT * 1e18) / currentPrice) * 10) / 100) -
            ((((amountUSDT * 1e18) / currentPrice) * ADMIN_FEE_BP) /
                10000);
        // 10% Tokens Burned
        cnxToken.burn(
            address(this),
            ((((amountUSDT * 1e18) / currentPrice) * 10) / 100)
        );
        // 5% Admin fee transferred
        cnxToken.transfer(
            admin,
            (((amountUSDT * 1e18) / currentPrice) * ADMIN_FEE_BP) /
                10000
        );
        // Balance 85% transferred to user
        cnxToken.transfer(msg.sender, userAmount);

        users[msg.sender].withdrawableBalance -= amountUSDT;
        users[msg.sender].totalWithdrawn += amountUSDT;
        users[msg.sender].lastWithdrawTime = block.timestamp;
        emit Withdraw(msg.sender, amountUSDT, userAmount, block.timestamp);
    }

    // --- Sell CNX to contract: 100% burned, user receives 95% USDT, 5% stays in contract ---
    function sellCNX(uint256 cnxAmount) external onlyRegistered nonReentrant {
        require(cnxToken.balanceOf(msg.sender) >= cnxAmount, "Not enough CNX");

        // uint256 usdtAmount = ((cnxAmount * getCurrentTokenPrice()) / 1e18);
        
        uint256 payout = (((cnxAmount * getCurrentTokenPrice()) / 1e18) * 95) /
            100;

        require(
            usdt.balanceOf(address(this)) >= payout,
            "Not enough USDT liquidity"
        );

        cnxToken.transferFrom(msg.sender, address(this), cnxAmount);
        cnxToken.burn(address(this), cnxAmount);

        usdt.transfer(msg.sender, payout);

        emit SoldCNXTokens(msg.sender, cnxAmount, payout);
        // 5% stays in contract for price appreciation
    }

    // --- Fast Start Bonus (event-based, no per-user history array) ---
    function _getQualifyingDirectTopups(
        address user,
        uint256 regTime,
        uint256 window
    ) private view returns (uint256[] memory, uint32) {
        address[] storage directs = users[user].directList;
        uint32 qualifyingDirects = 0;
        uint256[] memory directTopups = new uint256[](directs.length);
        for (uint32 i = 0; i < directs.length; ++i) {
            if (users[directs[i]].registrationTime <= regTime + window) {
                if (users[directs[i]].deposits.length > 0) {
                    directTopups[qualifyingDirects] = users[directs[i]]
                        .deposits[0]
                        .amount;
                    qualifyingDirects++;
                }
            }
        }
        return (directTopups, qualifyingDirects);
    }

    function claimFastStartBonus() external onlyRegistered nonReentrant {
        require(
            !users[msg.sender].fastStartClaimed,
            "Already claimed Fast Start Bonus"
        );

        uint256 regTime = users[msg.sender].registrationTime;

        require(
            block.timestamp >= regTime + FASTSTART_WINDOW,
            "Can claim only after 15 days"
        );
        require(
            block.timestamp <= regTime + FASTSTART_CLAIM_WINDOW,
            "Claim window expired"
        );

        (
            uint256[] memory directTopups,
            uint32 directs15
        ) = _getQualifyingDirectTopups(msg.sender, regTime, FASTSTART_WINDOW);

        require(
            directs15 >= 5,
            "Not enough qualifying directs in first 15 days"
        );

        uint256 bonusAmount;

        if (directs15 >= 25) {
            for (uint8 i = 0; i < 25; ++i)
                bonusAmount += (directTopups[i] * 10) / 100;
            users[msg.sender].fastStartBonus = bonusAmount;
            users[msg.sender].fastStartEligibleDirects = 25;
        } else if (directs15 >= 15) {
            for (uint8 i = 0; i < 15; ++i)
                bonusAmount += (directTopups[i] * 5) / 100;
            users[msg.sender].fastStartBonus = bonusAmount;
            users[msg.sender].fastStartEligibleDirects = 15;
        } else {
            for (uint8 i = 0; i < 5; ++i)
                bonusAmount += (directTopups[i] * 3) / 100;
            users[msg.sender].fastStartBonus = bonusAmount;
            users[msg.sender].fastStartEligibleDirects = 5;
        }

        require(bonusAmount > 0, "No eligible bonus");

        users[msg.sender].withdrawableBalance += bonusAmount;
        users[msg.sender].fastStartClaimed = true;
        users[msg.sender].fastStartClaimTime = block.timestamp;

        emit FastStartBonusClaimed(
            msg.sender,
            bonusAmount,
            users[msg.sender].fastStartEligibleDirects,
            block.timestamp
        );
    }

    // --- Token price: USDT in contract / CNX supply (returns price in 18 decimals) ---
    function getCurrentTokenPrice() public view returns (uint256) {
        uint256 supply = cnxToken.totalSupply();
        if (supply == 0) return INITIAL_TOKEN_PRICE;
        return ((usdt.balanceOf(address(this)) * 1e18) / supply);
    }

    function getWithdrawalInfo(
        address user
    )
        public
        view
        returns (
            uint256 withdrawableBalance,
            uint256 availableWithdrawLimit,
            uint256 lastWithdrawTime
        )
    {
        withdrawableBalance = users[user].withdrawableBalance;
        availableWithdrawLimit =
            users[user].totalTopup *
            WITHDRAW_CAP_X -
            users[user].totalWithdrawn;
        lastWithdrawTime = users[user].lastWithdrawTime;
    }

    function getFSBQualifyingData(
        address user
    )
        public
        view
        returns (
            uint256 registrationTime,
            uint256[] memory directTopups,
            address[] memory qualifyingDirects
        )
    {
        uint32 directCount = uint32(users[user].directList.length);
        // We can't know max size in advance, so allocate max possible, then trim
        address[] memory tmpQualifyingDirects = new address[](directCount);
        uint256[] memory tmpDirectTopups = new uint256[](directCount);
        uint32 noOfQualifyingDirects = 0;
        for (uint32 i = 0; i < directCount; ++i) {
            address direct = users[user].directList[i];
            if (
                users[direct].registrationTime <=
                users[user].registrationTime + FASTSTART_WINDOW
            ) {
                if (users[direct].deposits.length > 0) {
                    tmpDirectTopups[noOfQualifyingDirects] = users[direct]
                        .deposits[0]
                        .amount;
                    tmpQualifyingDirects[noOfQualifyingDirects] = direct;
                    noOfQualifyingDirects++;
                }
            }
        }
        // Resize arrays to actual number of qualifying directs
        address[] memory qualifyingDirectsFinal = new address[](
            noOfQualifyingDirects
        );
        uint256[] memory directTopupsFinal = new uint256[](
            noOfQualifyingDirects
        );
        for (uint32 j = 0; j < noOfQualifyingDirects; ++j) {
            qualifyingDirectsFinal[j] = tmpQualifyingDirects[j];
            directTopupsFinal[j] = tmpDirectTopups[j];
        }

        return (
            users[user].registrationTime,
            directTopupsFinal,
            qualifyingDirectsFinal
        );
    }

    // --- User and System View Functions for Frontend/Dashboard ---
    function getUserStats(
        address user
    )
        public
        view
        returns (
            address referrer,
            uint256 directs,
            uint256 registrationTime,
            uint256 totalTopup,
            uint256 totalEarning,
            uint256 referralBonus,
            uint256 withdrawableAmount,
            uint256 totalWithdrawn
        )
    {
        require(users[user].registered, "User not registered");

        referrer = users[user].referrer;
        directs = users[user].directList.length;
        registrationTime = users[user].registrationTime;
        totalTopup = users[user].totalTopup;
        totalEarning =
            users[user].totalRoiEarned +
            users[user].totalReferralBonusEarned +
            users[user].totalTeamRoiEarned +
            users[user].fastStartBonus;
        referralBonus = users[user].totalReferralBonusEarned;
        withdrawableAmount = users[user].withdrawableBalance;
        totalWithdrawn = users[user].totalWithdrawn;
    }

    function getUserDeposits(
        address user,
        uint256 start,
        uint256 count
    )
        public
        view
        returns (
            uint256[] memory amounts,
            uint256[] memory startTimes,
            uint256[] memory claimedROIs,
            uint256[] memory lastRoiClaims,
            bool[] memory closeds
        )
    {
        require(users[user].registered, "User not registered");
        uint256 len = users[user].deposits.length;
        if (start >= len) {
            amounts = new uint256[](0);
            startTimes = new uint256[](0);
            claimedROIs = new uint256[](0);
            lastRoiClaims = new uint256[](0);
            closeds = new bool[](0);
            return (amounts, startTimes, claimedROIs, lastRoiClaims, closeds);
        }
        uint256 end = (start + count > len) ? len : start + count;
        uint256 resultLen = end - start;
        amounts = new uint256[](resultLen);
        startTimes = new uint256[](resultLen);
        claimedROIs = new uint256[](resultLen);
        lastRoiClaims = new uint256[](resultLen);
        closeds = new bool[](resultLen);

        for (uint256 i = start; i < end; ++i) {
            amounts[i - start] = users[user].deposits[i].amount;
            startTimes[i - start] = users[user].deposits[i].startTime;
            claimedROIs[i - start] = users[user].deposits[i].claimedROI;
            lastRoiClaims[i - start] = users[user].deposits[i].lastRoiClaim;
            closeds[i - start] = users[user].deposits[i].closed;
        }
        return (amounts, startTimes, claimedROIs, lastRoiClaims, closeds);
    }

    function getDirectsWithTopups(
        address user,
        uint32 start,
        uint32 limit
    )
        public
        view
        returns (address[] memory directs, uint256[] memory totalTopups)
    {
        require(users[user].registered, "User not registered");
        uint256 totalDirects = users[user].directList.length;
        // Calculate the number of items to fetch
        uint32 end = start + limit > totalDirects
            ? uint32(totalDirects)
            : start + limit;
        uint32 resultCount = end > start ? end - start : 0;
        directs = new address[](resultCount);
        totalTopups = new uint256[](resultCount);

        for (uint32 i = 0; i < resultCount; ++i) {
            address direct = users[user].directList[start + i];
            directs[i] = direct;

            // Calculate total topup for each direct (sum of all deposits)
            uint256 topupSum = 0;
            for (uint256 j = 0; j < users[direct].deposits.length; ++j) {
                topupSum += users[direct].deposits[j].amount;
            }
            totalTopups[i] = topupSum;
        }
        return (directs, totalTopups);
    }

    function getDirectsTotalTopup(
        address user
    ) public view returns (uint256 totalTopup) {
        require(users[user].registered, "User not registered");
        uint256 len = users[user].directList.length;
        for (uint256 i = 0; i < len; ++i) {
            address direct = users[user].directList[i];
            for (uint256 j = 0; j < users[direct].deposits.length; ++j) {
                totalTopup += users[direct].deposits[j].amount;
            }
        }
    }

    function getCnxBalance(address user) external view returns (uint256) {
        return cnxToken.balanceOf(user);
    }

    function getSystemStats()
        public
        view
        returns (
            uint256 totalCnxSupply,
            uint256 totalUsdtInContract,
            uint256 currentCnxPrice
        )
    {
        return (
            cnxToken.totalSupply(),
            usdt.balanceOf(address(this)),
            getCurrentTokenPrice()
        );
    }

    function getDashboardData(
        address user
    )
        external
        view
        returns (
            uint256 totalCnxSupply,
            uint256 totalUsdtInContract,
            uint256 currentCnxPrice,
            address referrer,
            uint256 directs,
            uint256 registrationTime,
            uint256 totalTopup,
            uint256 totalEarning,
            uint256 referralBonus,
            uint256 withdrawableAmount,
            uint256 totalWithdrawn
        )
    {
        require(users[user].registered, "User not registered");
        // SYSTEM STATS
        (
            totalCnxSupply,
            totalUsdtInContract,
            currentCnxPrice
        ) = getSystemStats();
        // USER STATS
        (
            referrer,
            directs,
            registrationTime,
            totalTopup,
            totalEarning,
            referralBonus,
            withdrawableAmount,
            totalWithdrawn
        ) = getUserStats(user);
    }

    // --- Ownership renounce for full decentralization ---
    function renounceAllOwnerships() external onlyOwner {
        cnxToken.transferOwnership(address(0));
        _transferOwnership(address(0));
    }
}
