
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// OpenZeppelin ERC20/Ownable
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// --- CNX Token ---
contract CyranexToken is ERC20, Ownable {
    constructor(address initialOwner) ERC20("CYRANEX", "CNX") Ownable(initialOwner) {}
    function mint(address to, uint256 amount) external onlyOwner { _mint(to, amount); }
    function burn(address from, uint256 amount) external onlyOwner { _burn(from, amount); }
}

// --- MLM Contract ---
contract CyranexMLM is ReentrancyGuard, Ownable {
    IERC20 public immutable usdt;
    CyranexToken public immutable cnxToken;

    address public admin1;
    address public admin2;
    address public admin3;

    uint256 public constant MIN_TOPUP = 50 * 1e18;
    uint256 public constant ADMIN_FEE_BP = 500; // 5%
    uint256 public constant MINT_PERCENT_BP = 7000; // 70%
    uint256 public constant INITIAL_TOKEN_PRICE = 4e18;
    uint256 public constant WEEK = 7 days;
    uint256 public constant ROI_WEEKLY_BP = 350; // 3.5%
    uint256 public constant WITHDRAW_CAP_X = 2;
    uint256 public constant FASTSTART_WINDOW = 15 days;
    uint256 public constant FASTSTART_CLAIM_WINDOW = 30 days;

    uint16[20] public roiPercents = [
        1500, 500, 500, 400, 400, 300, 300, 200, 200, 100,
        100, 100, 50, 50, 50, 50, 50, 50, 50, 50
    ];

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
        uint256 directs;
        uint256 registrationTime;
        Deposit[] deposits;
        uint256 withdrawableBalance;
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

    mapping(address => User) public users;
    mapping(address => address[]) public downlines;

    // --- Events: Use these for all histories ---
    event Registered(address indexed user, address indexed referrer, uint256 time);
    event TopUp(address indexed user, uint256 amount, uint256 mintedCNX, uint256 time);
    event ClaimROI(address indexed user, uint256 depositIndex, uint256 roiAmount, uint256 time);
    event TeamRoiPaid(address indexed upline, address indexed downline, uint8 level, uint256 amount, uint256 time);
    event DirectReferralBonus(address indexed referrer, address indexed downline, uint256 topupAmount, uint256 bonusAmount, uint256 time);
    event Withdraw(address indexed user, uint256 usdtAmount, uint256 cnxAmount, uint256 time);
    event FastStartBonusClaimed(address indexed user, uint256 bonus, uint256 directs, uint256 time);

    // --- Prevent accidental BNB deposit ---
    receive() external payable { revert("Contract does not accept BNB"); }
    fallback() external payable { revert("Contract does not accept BNB"); }

    constructor(
        address _usdt,
        address _admin1,
        address _admin2,
        address _admin3,
        address _root
    ) Ownable(msg.sender) {
        require(_usdt != address(0), "Invalid USDT");
        require(_admin1 != address(0) && _admin2 != address(0) && _admin3 != address(0), "Invalid admin");
        require(_root != address(0), "Invalid root");
        usdt = IERC20(_usdt);
        admin1 = _admin1;
        admin2 = _admin2;
        admin3 = _admin3;
        cnxToken = new CyranexToken(address(this));
        // Set the root user (contract address as referrer)
        users[_root].registered = true;
        users[_root].referrer = address(this);
        users[_root].registrationTime = block.timestamp;
    }

    modifier onlyRegistered() {
        require(users[msg.sender].registered, "Not registered");
        _;
    }

    // --- Registration ---
    function register(address referrer) external {
        require(!users[msg.sender].registered, "Already registered");
        require(referrer != address(0) && users[referrer].registered, "Invalid referrer");
        users[msg.sender].registered = true;
        users[msg.sender].referrer = referrer;
        users[msg.sender].registrationTime = block.timestamp;
        users[referrer].directList.push(msg.sender);
        users[referrer].directs += 1;
        downlines[referrer].push(msg.sender);
        emit Registered(msg.sender, referrer, block.timestamp);
    }

    // --- Top-Up ---
    function topUp(uint256 amount) external onlyRegistered nonReentrant {
        require(amount >= MIN_TOPUP && amount % MIN_TOPUP == 0, "Invalid top-up amount");
        require(usdt.transferFrom(msg.sender, address(this), amount), "USDT transfer failed");

        uint256 adminFee = (amount * ADMIN_FEE_BP) / 10000;
        
        usdt.transfer(admin1, (adminFee * 2) / 5);
        usdt.transfer(admin2, (adminFee * 2) / 5);
        usdt.transfer(admin3, (adminFee * 1) / 5);

        uint256 mintBase = (amount * MINT_PERCENT_BP) / 10000;
        uint256 cnxPrice = getCurrentTokenPrice();
        uint256 mintCNX = cnxToken.totalSupply() == 0
            ? (mintBase * 1e18) / INITIAL_TOKEN_PRICE
            : (mintBase * 1e18) / cnxPrice;
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
            emit DirectReferralBonus(referrer, msg.sender, amount, referralBonus, block.timestamp);
        }

        emit TopUp(msg.sender, amount, mintCNX, block.timestamp);
    }

    // --- Claim ROI (one week per claim per deposit, plus Team ROI) ---
    function claimROI() external onlyRegistered nonReentrant {
        User storage user = users[msg.sender];
        uint256 totalRoi;

        for (uint256 i = 0; i < user.deposits.length; ++i) {
            Deposit storage dep = user.deposits[i];
            if (dep.closed) continue;
            if (block.timestamp < dep.lastRoiClaim + WEEK) continue;
            uint256 maxRoiLeft = (dep.amount * WITHDRAW_CAP_X) - dep.claimedROI;
            if (maxRoiLeft == 0) {
                dep.closed = true;
                continue;
            }
            uint256 roiForPeriod = (dep.amount * ROI_WEEKLY_BP) / 10000;
            if (roiForPeriod > maxRoiLeft) {
                roiForPeriod = maxRoiLeft;
                dep.closed = true;
            }
            dep.claimedROI += roiForPeriod;
            dep.lastRoiClaim = block.timestamp;
            totalRoi += roiForPeriod;
            emit ClaimROI(msg.sender, i, roiForPeriod, block.timestamp);
        }

        if(totalRoi > 0){
            user.withdrawableBalance += totalRoi;
            user.totalRoiEarned += totalRoi;        

            // Team ROI Bonus up to 20 levels
            address currentUpline = user.referrer;
            for (uint8 level = 0; level < 20 && currentUpline != address(0); level++) {
                if (users[currentUpline].directs >= (level + 1)) {
                    uint256 bonus = (totalRoi * roiPercents[level]) / 10000;
                    users[currentUpline].withdrawableBalance += bonus;
                    users[currentUpline].totalTeamRoiEarned += bonus;
                    emit TeamRoiPaid(currentUpline, msg.sender, level + 1, bonus, block.timestamp);
                }
                currentUpline = users[currentUpline].referrer;
            }
        }
    }

    // --- Withdraw earnings (capped at 2x total top-up per user) ---
    function withdraw(uint256 amountUSDT) external onlyRegistered nonReentrant {
        require(amountUSDT >= 10 * 1e18 && amountUSDT % (10 * 1e18) == 0, "Minimum withdrawal is $10 or multiple of $10");
        User storage user = users[msg.sender];
        require(user.withdrawableBalance >= amountUSDT, "Insufficient withdrawable");
        require(
            user.totalWithdrawn + amountUSDT <= user.totalTopup * WITHDRAW_CAP_X,
            "2x withdrawal cap reached"
        );
        uint256 cnxPrice = getCurrentTokenPrice();
        uint256 cnxAmount = (amountUSDT * 1e18) / cnxPrice;
        uint256 burnAmount = (cnxAmount * 10) / 100;
        uint256 adminAmount = (cnxAmount * 5) / 100;
        uint256 userAmount = cnxAmount - burnAmount - adminAmount;
        cnxToken.burn(address(this), burnAmount);
        cnxToken.transfer(admin1, (adminAmount * 2) / 5);
        cnxToken.transfer(admin2, (adminAmount * 2) / 5);
        cnxToken.transfer(admin3, adminAmount - (adminAmount * 4) / 5);
        cnxToken.transfer(msg.sender, userAmount);
        user.withdrawableBalance -= amountUSDT;
        user.totalWithdrawn += amountUSDT;
        emit Withdraw(msg.sender, amountUSDT, userAmount, block.timestamp);
    }

    // --- Sell CNX to contract: 100% burned, user receives 95% USDT, 5% stays in contract ---
    function sellCNX(uint256 cnxAmount) external onlyRegistered nonReentrant {
        require(cnxToken.balanceOf(msg.sender) >= cnxAmount, "Not enough CNX");
        uint256 cnxPrice = getCurrentTokenPrice();
        uint256 usdtAmount = (cnxAmount * cnxPrice) / 1e18;
        uint256 payout = (usdtAmount * 95) / 100;
        require(usdt.balanceOf(address(this)) >= payout, "Not enough USDT liquidity");
        cnxToken.transferFrom(msg.sender, address(this), cnxAmount);
        cnxToken.burn(address(this), cnxAmount);
        usdt.transfer(msg.sender, payout);
        // 5% stays in contract for price appreciation
    }

    // --- Fast Start Bonus (event-based, no per-user history array) ---
    function _getQualifyingDirectTopups(
        address user,
        uint256 regTime,
        uint256 window
    ) private view returns (uint256[] memory, uint256) {
        address[] storage directs = users[user].directList;
        uint256 qualifyingDirects = 0;
        uint256[] memory directTopups = new uint256[](directs.length);
        for (uint256 i = 0; i < directs.length; ++i) {
            if (users[directs[i]].registrationTime <= regTime + window) {
                if (users[directs[i]].deposits.length > 0) {
                    directTopups[qualifyingDirects] = users[directs[i]].deposits[0].amount;
                    qualifyingDirects++;
                }
            }
        }
        return (directTopups, qualifyingDirects);
    }

    function claimFastStartBonus() external onlyRegistered nonReentrant {
        User storage user = users[msg.sender];
        require(!user.fastStartClaimed, "Already claimed Fast Start Bonus");
        uint256 regTime = user.registrationTime;
        require(block.timestamp >= regTime + FASTSTART_WINDOW, "Can claim only after 15 days");
        require(block.timestamp <= regTime + FASTSTART_CLAIM_WINDOW, "Claim window expired");
        (uint256[] memory directTopups, uint256 directs15) =
            _getQualifyingDirectTopups(msg.sender, regTime, FASTSTART_WINDOW);
        require(directs15 >= 5, "Not enough qualifying directs in first 15 days");
        uint256 bonusAmount;
        if (directs15 >= 25) {
            for (uint256 i = 0; i < 25; ++i) bonusAmount += (directTopups[i] * 10) / 100;
            user.fastStartBonus = bonusAmount;
            user.fastStartEligibleDirects = 25;
        } else if (directs15 >= 15) {
            for (uint256 i = 0; i < 15; ++i) bonusAmount += (directTopups[i] * 5) / 100;
            user.fastStartBonus = bonusAmount;
            user.fastStartEligibleDirects = 15;
        } else {
            for (uint256 i = 0; i < 5; ++i) bonusAmount += (directTopups[i] * 3) / 100;
            user.fastStartBonus = bonusAmount;
            user.fastStartEligibleDirects = 5;
        }
        require(bonusAmount > 0, "No eligible bonus");
        user.withdrawableBalance += bonusAmount;
        user.fastStartClaimed = true;
        user.fastStartClaimTime = block.timestamp;
        emit FastStartBonusClaimed(msg.sender, bonusAmount, user.fastStartEligibleDirects, block.timestamp);
    }

    // --- Token price: USDT in contract / CNX supply (returns price in 18 decimals) ---
    function getCurrentTokenPrice() public view returns (uint256) {
        uint256 supply = cnxToken.totalSupply();
        if (supply == 0) return INITIAL_TOKEN_PRICE;
        return (usdt.balanceOf(address(this)) * 1e18) / supply;
    }

    // --- User and System View Functions for Frontend/Dashboard ---
    function getUserProfile(address user)
        external
        view
        returns (
            bool registered,
            address referrer,
            uint256 directs,
            uint256 registrationTime,
            uint256 totalTopup,
            uint256 totalWithdrawn,
            uint256 withdrawableBalance,
            uint256 totalTeamRoiEarned
        )
    {
        User storage u = users[user];
        return (
            u.registered,
            u.referrer,
            u.directs,
            u.registrationTime,
            u.totalTopup,
            u.totalWithdrawn,
            u.withdrawableBalance,
            u.totalTeamRoiEarned
        );
    }

    function getUserDeposits(address user, uint256 start, uint256 count)
        external
        view
        returns (Deposit[] memory deposits)
    {
        uint256 len = users[user].deposits.length;
        if (start >= len) return new Deposit[] (0);
        uint256 end = (start + count > len) ? len : start + count;
        deposits = new Deposit[](end - start);
        for (uint256 i = start; i < end; ++i) {
            deposits[i - start] = users[user].deposits[i];
        }
    }

    function getDirectReferrals(address user) external view returns (address[] memory) {
        return users[user].directList;
    }

    function getCnxBalance(address user) external view returns (uint256) {
        return cnxToken.balanceOf(user);
    }

    function getSystemStats()
        external
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

    function getUserFinancials(address user)
        external
        view
        returns (
            uint256 withdrawableBalance,
            uint256 totalWithdrawn,
            uint256 totalTopup,
            uint256 totalReferralBonusEarned,
            uint256 totalTeamRoiEarned,
            uint256 totalRoiEarned
        )
    {
        User storage u = users[user];
        return (
            u.withdrawableBalance,
            u.totalWithdrawn,
            u.totalTopup,
            u.totalReferralBonusEarned,
            u.totalTeamRoiEarned,
            u.totalRoiEarned
        );
    }


    // --- Ownership renounce for full decentralization ---
    function renounceAllOwnerships() external onlyOwner {
        cnxToken.transferOwnership(address(0));
        _transferOwnership(address(0));
    }
}
