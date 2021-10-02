// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

//chainlink oracle interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt,uint80 answeredInRound);
}

//prediction contracts are owned by the PredictionFactory contract
contract Prediction is Ownable, Pausable, ReentrancyGuard {

    struct Round {
        uint32 startTimestamp;
        uint32 lockTimestamp;
        uint32 closeTimestamp;
        bool oracleCalled;
        uint256 bullAmount;
        uint256 bearAmount;
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
        uint256 treasuryAmount;
        uint256 bullBonusAmount;
        uint256 bearBonusAmount;
        int256 lockPrice;
        int256 closePrice;
    }

    enum Position {Bull, Bear}

    struct BetInfo {
        Position position;
        uint256 amount;
        uint256 refereeAmount;
        uint256 referrerAmount;
        uint256 stakingAmount;
        bool claimed;
    }

    IERC20 public betToken;

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(address => uint256) public userReferenceBonuses;
    mapping(address => uint256) public totalUserReferenceBonuses;
    uint256 public currentEpoch;
    uint32 public intervalSeconds;
    uint32 public bufferSeconds;
    uint256 public treasuryAmount;
    AggregatorV3Interface public oracle;
    uint256 public oracleLatestRoundId;

    uint256 public constant TOTAL_RATE = 100;
    uint256 public rewardRate;
    uint256 public treasuryRate;
    uint256 public referrerRate;
    uint256 public refereeRate;
    uint256 public minBetAmount;
    uint256 public oracleUpdateAllowance; // seconds

    bool public genesisStartOnce = false;
    bool public genesisLockOnce = false;

    bool public initialized = false;

    IReferral public referralSystem;
    IStaker public staker;
    uint[] public stakingBonuses;

    event PredictionsStartRound(uint256 indexed epoch, uint256 blockNumber);
    event PredictionsLockRound(uint256 indexed epoch, uint256 blockNumber, int256 price);
    event PredictionsEndRound(uint256 indexed epoch, uint256 blockNumber, int256 price);
    event PredictionsPause(uint256 epoch);
    event PredictionsUnpause(uint256 epoch);
    event PredictionsBet(address indexed sender, uint256 indexed currentEpoch, uint256 amount, uint256 refereeAmount, uint256 stakingAmount, uint8 position);
    event PredictionsClaim(address indexed sender, uint256 indexed currentEpoch, uint256 amount);
    event PredictionsRewardsCalculated(uint256 indexed currentEpoch, int8 position, uint256 rewardBaseCalAmount, uint256 rewardAmount, uint256 treasuryAmount);
    event PredictionsReferrerBonus(address indexed user, address indexed referrer, uint256 amount, uint256 indexed currentEpoch);
    event PredictionsSetReferralRates(uint256 currentEpoch, uint256 _referrerRate, uint256 _refereeRate);
    event PredictionsSetOracle(uint256 currentEpoch, address _oracle);
    event PredictionsSetTreasuryRate(uint256 currentEpoch, uint256 _treasuryRate);
    event PredictionsSetStakingLevelBonuses(uint256 currentEpoch, uint256[] _bonuses);

    constructor() {
        //index 0 for staking bonuses is always 0
        stakingBonuses.push(0);
    }

    function initialize(
        AggregatorV3Interface _oracle,
        uint32 _intervalSeconds,
        uint32 _bufferSeconds,
        uint256 _minBetAmount,
        uint256 _oracleUpdateAllowance,
        IERC20 _betToken,
        uint256 _treasuryRate,
        uint256 _referrerRate,
        uint256 _refereeRate,
        address _referralSystemAddress,
        address _stakerAddress
    ) external onlyOwner {
        require(!initialized);
        require(_treasuryRate <= 10, "<10");
        require(_referrerRate + _refereeRate <= 100, "<100");

        initialized = true;

        oracle = _oracle;
        intervalSeconds = _intervalSeconds;
        bufferSeconds = _bufferSeconds;
        minBetAmount = _minBetAmount;
        oracleUpdateAllowance = _oracleUpdateAllowance;

        betToken = _betToken;

        rewardRate = TOTAL_RATE - _treasuryRate;
        treasuryRate = _treasuryRate;
        referrerRate = _referrerRate;
        refereeRate = _refereeRate;

        referralSystem = IReferral(_referralSystemAddress);
        staker = IStaker(_stakerAddress);
    }

    /**
     * @dev set interval blocks
     * callable by owner
     */
    function setIntervalSeconds(uint32 _intervalSeconds) external onlyOwner {
        intervalSeconds = _intervalSeconds;
    }

    /**
     * @dev set buffer blocks
     * callable by owner
     */
    function setBufferSeconds(uint32 _bufferSeconds) external onlyOwner {
        require(_bufferSeconds <= intervalSeconds);
        bufferSeconds = _bufferSeconds;
    }

    /**
     * @dev set Oracle address
     * callable by owner
     */
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0));
        oracle = AggregatorV3Interface(_oracle);
        emit PredictionsSetOracle(currentEpoch, _oracle);
    }

    /**
     * @dev set oracle update allowance
     * callable by owner
     */
    function setOracleUpdateAllowance(uint256 _oracleUpdateAllowance) external onlyOwner {
        oracleUpdateAllowance = _oracleUpdateAllowance;
    }

    /**
     * @dev set treasury rate
     * callable by owner
     */
    function setTreasuryRate(uint256 _treasuryRate) external onlyOwner {
        require(_treasuryRate <= 10, "<10");

        rewardRate = TOTAL_RATE - _treasuryRate;
        treasuryRate = _treasuryRate;
        
        emit PredictionsSetTreasuryRate(currentEpoch, _treasuryRate);
    }

    /**
     * @dev set minBetAmount
     * callable by owner
     */
    function setMinBetAmount(uint256 _minBetAmount) external onlyOwner {
        minBetAmount = _minBetAmount;
    }

    /**
     * @dev Start genesis round
     */
    function genesisStartRound() external onlyOwner whenNotPaused {
        require(!genesisStartOnce);

        currentEpoch = currentEpoch + 1;
        _startRound(currentEpoch);
        genesisStartOnce = true;
    }

    /**
     * @dev Lock genesis round
     */
    function genesisLockRound() external onlyOwner whenNotPaused {
        require(genesisStartOnce, "req genesisStart");
        require(!genesisLockOnce);
        require(block.timestamp <= rounds[currentEpoch].lockTimestamp + bufferSeconds,">buffer");

        int256 currentPrice = _getPriceFromOracle();
        _safeLockRound(currentEpoch, currentPrice);

        currentEpoch = currentEpoch + 1;
        _startRound(currentEpoch);
        genesisLockOnce = true;
    }

    /**
     * @dev Start the next round n, lock price for round n-1, end round n-2
     */
    function executeRound() external onlyOwner whenNotPaused {
        require(genesisStartOnce && genesisLockOnce, "req genesis");

        int256 currentPrice = _getPriceFromOracle();
        // CurrentEpoch refers to previous round (n-1)
        _safeLockRound(currentEpoch, currentPrice);
        _safeEndRound(currentEpoch - 1, currentPrice);
        _calculateRewards(currentEpoch - 1);

        // Increment currentEpoch to current round (n)
        currentEpoch = currentEpoch + 1;
        _safeStartRound(currentEpoch);
    }

    /**
     * @dev Bet bear position
     */
    function betBear(uint256 epoch, address user, uint256 amount) external whenNotPaused nonReentrant onlyOwner {
        require(epoch == currentEpoch, "Bet earlylate");
        require(_bettable(currentEpoch), "not bettable");
        require(amount >= minBetAmount);
        require(ledger[currentEpoch][user].amount == 0, "alreadybet");

        // Update round data
        Round storage round = rounds[currentEpoch];
        round.bearAmount = round.bearAmount + amount;

        //if the user has a referrer, set the referral bonuses and subtract it from the treasury amount
        uint refereeAmt = 0;
        uint referrerAmt = 0;
        uint stakingAmt = 0;
        uint treasuryAmt = amount * treasuryRate / TOTAL_RATE;
        
        //check and set referral bonuses
        if(referralSystem.hasReferrer(user))
        {
            refereeAmt = treasuryAmt * refereeRate / 100;
            referrerAmt = treasuryAmt * referrerRate / 100;
            round.bearBonusAmount = round.bearBonusAmount + refereeAmt + referrerAmt;
        }

        //check and set staking bonuses
        uint stakingLvl = staker.getUserStakingLevel(user);
        if(stakingLvl > 0 && stakingBonuses.length > stakingLvl)
        {
            stakingAmt = treasuryAmt * stakingBonuses[stakingLvl] / 100;
            round.bearBonusAmount = round.bearBonusAmount + stakingAmt;
        }

        //round treasury amount includes the staking and referral bonuses until the calculation
        //these amounts will be deducted on rewards calculation
        round.treasuryAmount = round.treasuryAmount + treasuryAmt;

        // Update user data
        BetInfo storage betInfo = ledger[currentEpoch][user];
        betInfo.position = Position.Bear;
        betInfo.amount = amount;
        betInfo.refereeAmount = refereeAmt;
        betInfo.referrerAmount = referrerAmt;
        betInfo.stakingAmount = stakingAmt;

        emit PredictionsBet(user, epoch, amount, refereeAmt, stakingAmt, 1);
    }

    /**
     * @dev Bet bull position
     */
    function betBull(uint256 epoch, address user, uint256 amount) external whenNotPaused nonReentrant onlyOwner {
        require(epoch == currentEpoch, "Bet earlylate");
        require(_bettable(currentEpoch), "not bettable");
        require(amount >= minBetAmount);
        require(ledger[currentEpoch][user].amount == 0, "alreadybet");

        // Update round data
        Round storage round = rounds[currentEpoch];
        round.bullAmount = round.bullAmount + amount;

        //if the user has a referrer, set the referral bonuses and subtract it from the treasury amount
        uint refereeAmt = 0;
        uint referrerAmt = 0;
        uint stakingAmt = 0;
        uint treasuryAmt = amount * treasuryRate / TOTAL_RATE;

        //check and set referral bonuses
        if(referralSystem.hasReferrer(user))
        {
            refereeAmt = treasuryAmt * refereeRate / 100;
            referrerAmt = treasuryAmt * referrerRate / 100;
            round.bullBonusAmount = round.bullBonusAmount + refereeAmt + referrerAmt;
        }

        //check and set staking bonuses
        uint stakingLvl = staker.getUserStakingLevel(user);
        if(stakingLvl > 0 && stakingBonuses.length > stakingLvl)
        {
            stakingAmt = treasuryAmt * stakingBonuses[stakingLvl] / 100;
            round.bullBonusAmount = round.bullBonusAmount + stakingAmt;
        }

        //round treasury amount includes the staking and referral bonuses until the calculation
        //these amounts will be deducted on rewards calculation
        round.treasuryAmount = round.treasuryAmount + treasuryAmt;

        // Update user data
        BetInfo storage betInfo = ledger[currentEpoch][user];
        betInfo.position = Position.Bull;
        betInfo.amount = amount;
        betInfo.refereeAmount = refereeAmt;
        betInfo.referrerAmount = referrerAmt;
        betInfo.stakingAmount = stakingAmt;

        emit PredictionsBet(user, epoch, amount, refereeAmt, stakingAmt, 0);
    }

    function hasReferenceBonus(address _user) external view returns (bool) {
        return userReferenceBonuses[_user] > 0;
    }

    function claimReferenceBonus(address _user) external nonReentrant onlyOwner {
        require(userReferenceBonuses[_user] > 0, "nobonuses");
        uint reward = userReferenceBonuses[_user];
        userReferenceBonuses[_user] = 0;
        _safeTransferbetToken(_user, reward);
    }

    /**
     * @dev Claim reward
     */
    function claim(address user, uint256[] calldata epochs) external nonReentrant onlyOwner {
        uint256 reward; // Initializes reward

        for (uint256 i = 0; i < epochs.length; i++) {
            require(rounds[epochs[i]].startTimestamp != 0);
            require(block.timestamp > rounds[epochs[i]].closeTimestamp);

            uint256 addedReward = 0;
            BetInfo storage betInfo = ledger[epochs[i]][user];

            // Round valid, claim rewards
            if (rounds[epochs[i]].oracleCalled) {
                require(claimable(epochs[i], user), "No claim");
                Round memory round = rounds[epochs[i]];
                addedReward = betInfo.amount * round.rewardAmount / round.rewardBaseCalAmount + betInfo.refereeAmount + betInfo.stakingAmount;

                //if there is a referrer bonus, add it to that user's referrer bonus amount so they can claim it themselves
                if(betInfo.referrerAmount > 0)
                {
                    address referrerUser = referralSystem.getReferrer(user);
                    userReferenceBonuses[referrerUser] = userReferenceBonuses[referrerUser] + betInfo.referrerAmount;
                    totalUserReferenceBonuses[referrerUser] = totalUserReferenceBonuses[referrerUser] + betInfo.referrerAmount;

                    emit PredictionsReferrerBonus(user, referrerUser, betInfo.referrerAmount, epochs[i]);
                }
            }
            // Round invalid, refund bet amount
            else {
                require(refundable(epochs[i], user), "No refund");
                addedReward = betInfo.amount;
            }

            betInfo.claimed = true;
            reward = reward + addedReward;

            emit PredictionsClaim(user, epochs[i], addedReward);
        }

        if (reward > 0) {
            _safeTransferbetToken(user, reward);
        }
    }

    /**
     * @dev Claim all rewards in treasury
     * callable by owner
     */
    function claimTreasury(address _recipient) external nonReentrant onlyOwner {
        uint256 currentTreasuryAmount = treasuryAmount;
        treasuryAmount = 0;
        _safeTransferbetToken(_recipient, currentTreasuryAmount);
    }

    /**
     * @dev called by the owner to pause, triggers stopped state
     */
    function pause() external onlyOwner whenNotPaused {
        _pause();

        emit PredictionsPause(currentEpoch);
    }

    /**
     * @dev called by the owner to unpause, returns to normal state
     * Reset genesis state. Once paused, the rounds would need to be kickstarted by genesis
     */
    function unpause() external onlyOwner whenPaused {
        genesisStartOnce = false;
        genesisLockOnce = false;
        _unpause();

        emit PredictionsUnpause(currentEpoch);
    }

    /**
     * @dev Get the claimable stats of specific epoch and user account
     */
    function claimable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];
        if (round.lockPrice == round.closePrice) {
            return false;
        }
        return
            round.oracleCalled && betInfo.amount > 0 && !betInfo.claimed &&
            ((round.closePrice > round.lockPrice && betInfo.position == Position.Bull) ||
                (round.closePrice < round.lockPrice && betInfo.position == Position.Bear));
    }

    /**
     * @dev Get the refundable stats of specific epoch and user account
     */
    function refundable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];
        return !round.oracleCalled && block.timestamp > (round.closeTimestamp + bufferSeconds) && betInfo.amount != 0 && !betInfo.claimed;
    }

    function oracleInfo() external view returns (address) {
        return address(oracle);
    }

    /**
     * @dev Start round
     * Previous round n-2 must end
     */
    function _safeStartRound(uint256 epoch) internal {
        require(genesisStartOnce, "req gnsstart");
        require(rounds[epoch - 2].closeTimestamp != 0);
        require(block.timestamp >= rounds[epoch - 2].closeTimestamp);
        _startRound(epoch);
    }

    function _startRound(uint256 epoch) internal {
        Round storage round = rounds[epoch];
        round.startTimestamp = uint32(block.timestamp);
        round.lockTimestamp = uint32(block.timestamp) + intervalSeconds;
        round.closeTimestamp = uint32(block.timestamp) + (intervalSeconds * 2);

        emit PredictionsStartRound(epoch, block.timestamp);
    }

    /**
     * @dev Lock round
     */
    function _safeLockRound(uint256 epoch, int256 price) internal {
        require(rounds[epoch].startTimestamp != 0);
        require(block.timestamp >= rounds[epoch].lockTimestamp);
        require(block.timestamp <= rounds[epoch].lockTimestamp + bufferSeconds, ">buffer");
        _lockRound(epoch, price);
    }

    function _lockRound(uint256 epoch, int256 price) internal {
        Round storage round = rounds[epoch];
        round.lockPrice = price;

        emit PredictionsLockRound(epoch, block.timestamp, round.lockPrice);
    }

    /**
     * @dev End round
     */
    function _safeEndRound(uint256 epoch, int256 price) internal {
        require(rounds[epoch].lockTimestamp != 0);
        require(block.timestamp >= rounds[epoch].closeTimestamp);
        require(block.timestamp <= rounds[epoch].closeTimestamp + bufferSeconds, ">buffer");
        _endRound(epoch, price);
    }

    function _endRound(uint256 epoch, int256 price) internal {
        Round storage round = rounds[epoch];
        round.closePrice = price;
        round.oracleCalled = true;

        emit PredictionsEndRound(epoch, block.timestamp, round.closePrice);
    }

    /**
     * @dev Calculate rewards for round
     */
    function _calculateRewards(uint256 epoch) internal {
        require(rounds[epoch].rewardBaseCalAmount == 0 && rounds[epoch].rewardAmount == 0);
        Round storage round = rounds[epoch];
        uint256 rewardBaseCalAmount;
        uint256 rewardAmount;
        uint256 treasuryAmt;
        int8 position = -1;
        // Bull wins
        if (round.closePrice > round.lockPrice) {
            rewardBaseCalAmount = round.bullAmount;
            //round treasury amount includes the referral bonuses at this stage, so deducting it from the total amount
            rewardAmount = round.bearAmount + round.bullAmount - round.treasuryAmount;
            //bonus amount from the fees of the winning side is deducted from the total treasury amount
            treasuryAmt = round.treasuryAmount - round.bullBonusAmount;
            position = 0;
        }
        // Bear wins
        else if (round.closePrice < round.lockPrice) {
            rewardBaseCalAmount = round.bearAmount;
            //round treasury amount includes the referral bonuses at this stage, so deducting it from the total amount
            rewardAmount = round.bearAmount + round.bullAmount - round.treasuryAmount;
            //bonus amount from the fees of the winning side is deducted from the total treasury amount
            treasuryAmt = round.treasuryAmount - round.bearBonusAmount;
            position = 1;
        }
        // House wins
        else {
            rewardBaseCalAmount = 0;
            rewardAmount = 0;
            treasuryAmt = round.bearAmount + round.bullAmount;
        }
        round.rewardBaseCalAmount = rewardBaseCalAmount;
        round.treasuryAmount = treasuryAmt;
        round.rewardAmount = rewardAmount;

        // Add to treasury
        treasuryAmount = treasuryAmount + treasuryAmt;

        emit PredictionsRewardsCalculated(epoch, position, rewardBaseCalAmount, rewardAmount, treasuryAmt);
    }

    /**
     * @dev Get latest recorded price from oracle
     * If it falls below allowed buffer or has not updated, it would be invalid
     */
    function _getPriceFromOracle() internal returns (int256) {
        uint256 leastAllowedTimestamp = block.timestamp + oracleUpdateAllowance;
        (uint80 roundId, int256 price, , uint256 timestamp, ) = oracle.latestRoundData();
        require(timestamp <= leastAllowedTimestamp);
        require(roundId > oracleLatestRoundId, "same oracle rnd");
        oracleLatestRoundId = uint256(roundId);
        return price;
    }

    function _safeTransferbetToken(address to, uint256 value) internal {
        betToken.transfer(to, value);
    }

    /**
     * @dev Determine if a round is valid for receiving bets
     * Round must have started and locked
     * Current block must be within startTimestamp and closeTimestamp
     */
    function _bettable(uint256 epoch) internal view returns (bool) {
        return
            rounds[epoch].startTimestamp != 0 &&
            rounds[epoch].lockTimestamp != 0 &&
            block.timestamp > rounds[epoch].startTimestamp &&
            block.timestamp < rounds[epoch].lockTimestamp;
    }

    /**
     * @notice It allows the owner to recover tokens sent to the contract by mistake
     * @param _token: token address
     * @param _amount: token amount
     * @dev Callable by owner
     */
    function recoverToken(address _token, uint256 _amount, address receiver) external nonReentrant onlyOwner {
        IERC20(_token).transfer(receiver, _amount);
    }

    function setReferralRates(uint256 _referrerRate, uint256 _refereeRate) external onlyOwner {
        require(_referrerRate + _refereeRate + stakingBonuses[stakingBonuses.length - 1] <= 100, "<100");
        referrerRate = _referrerRate;
        refereeRate = _refereeRate;

        emit PredictionsSetReferralRates(currentEpoch, _referrerRate, _refereeRate);
    }

    function setStaker(address _stakerAddress) external onlyOwner {
        staker = IStaker(_stakerAddress);
    }

    function setReferralSystem(address _referralSystemAddress) external onlyOwner {
        referralSystem = IReferral(_referralSystemAddress);
    }

    function setStakingLevelBonuses(uint256[] calldata _bonuses) external onlyOwner {
        require(_bonuses[_bonuses.length - 1] + refereeRate + referrerRate <= 100, "<100");
        require(_bonuses[0] == 0, "l0is0");
        for (uint256 i = 0; i < _bonuses.length - 1; i++) {
            require(_bonuses[i] <= _bonuses[i+1],"reqhigher");
        }
        delete stakingBonuses;
        stakingBonuses = _bonuses;
        emit PredictionsSetStakingLevelBonuses(currentEpoch, _bonuses);
    }

}

interface IStaker {
    function deposit(uint _amount, uint _stakingLevel) external returns (bool);
    function withdraw(uint256 _amount) external returns (bool);
    function getUserStakingLevel(address _user) external view returns (uint);
}

contract PredictionStaker is IStaker, Ownable, ReentrancyGuard {

    IERC20 public stakingToken;
    uint256 public totalStaked;

    struct stakingInfo {
        uint amount;
        uint releaseDate;
        uint stakingLevel;
        uint requiredAmount;
    }

    struct stakingType {
        uint duration;
        uint requiredAmount;
    }

    mapping(address => stakingInfo) public userStakeInfo; 
    mapping(uint => stakingType) public stakingLevels;
    uint public maxStakingLevel;

    event PredictionsStakingSetToken(address indexed tokenAddress);
    event PredictionsStakingSetLevel(uint levelNo, uint duration, uint requiredAmount);
    event PredictionsStakingDeposit(address indexed user, uint256 amount, uint256 stakingLevel, uint256 releaseDate);
    event PredictionsStakingWithdraw(address indexed user, uint256 amount, uint256 stakingLevel);

    function setStakingToken(address _tokenAddress) external onlyOwner {
        stakingToken = IERC20(_tokenAddress);
        emit PredictionsStakingSetToken(_tokenAddress);
    }

    function setStakingLevel(uint _levelNo, uint _duration, uint _requiredAmount) external onlyOwner {
        require(_levelNo > 0, "level 0 should be empty");
        stakingLevels[_levelNo].duration = _duration;
        stakingLevels[_levelNo].requiredAmount = _requiredAmount;
        if(_levelNo>maxStakingLevel)
        {
            maxStakingLevel = _levelNo;
        }
        emit PredictionsStakingSetLevel(_levelNo, _duration, _requiredAmount);
    }

    function getStakingLevel(uint _levelNo) external view returns (uint duration, uint requiredAmount) {
        require(_levelNo <= maxStakingLevel, "Given staking level does not exist.");
        require(_levelNo > 0, "level 0 is not available");
        return(stakingLevels[_levelNo].duration, stakingLevels[_levelNo].requiredAmount);
    }

    function deposit(uint _amount, uint _stakingLevel) override external returns (bool){
        require(_stakingLevel > 0, "level 0 is not available");
        require(maxStakingLevel >= _stakingLevel, "Given staking level does not exist.");
        require(userStakeInfo[msg.sender].stakingLevel < _stakingLevel, "User already has a higher or same stake");
        require(userStakeInfo[msg.sender].amount + _amount == stakingLevels[_stakingLevel].requiredAmount, "You need to stake required amount.");
        require(stakingToken.transferFrom(msg.sender, address(this), _amount));

        if (userStakeInfo[msg.sender].amount == 0){
            userStakeInfo[msg.sender].amount = _amount;
        }else{
            userStakeInfo[msg.sender].amount = userStakeInfo[msg.sender].amount + _amount;
        }
        totalStaked = totalStaked + _amount;

        userStakeInfo[msg.sender].stakingLevel = _stakingLevel;
        userStakeInfo[msg.sender].requiredAmount = stakingLevels[_stakingLevel].requiredAmount;
        userStakeInfo[msg.sender].releaseDate = block.timestamp + stakingLevels[_stakingLevel].duration;

        emit PredictionsStakingDeposit(msg.sender, _amount, _stakingLevel, userStakeInfo[msg.sender].releaseDate);

        return true;
    }

    function withdraw(uint256 _amount) override external nonReentrant returns (bool) {
        require(userStakeInfo[msg.sender].amount >= _amount, "You do not have the entered amount.");
        require(userStakeInfo[msg.sender].releaseDate <= block.timestamp ||
                userStakeInfo[msg.sender].amount - _amount >= userStakeInfo[msg.sender].requiredAmount, 
                "You can't withdraw until your staking period is complete.");
        userStakeInfo[msg.sender].amount = userStakeInfo[msg.sender].amount - _amount;
        if(userStakeInfo[msg.sender].amount < stakingLevels[userStakeInfo[msg.sender].stakingLevel].requiredAmount)
        {
            userStakeInfo[msg.sender].stakingLevel = 0;
        }
        stakingToken.transfer(msg.sender, _amount);

        emit PredictionsStakingWithdraw(msg.sender, _amount, userStakeInfo[msg.sender].stakingLevel);

        return true;
    }

    function getUserStakingLevel(address _user) override external view returns (uint) {
        return userStakeInfo[_user].stakingLevel;
    }

    function getUserBalance(address _user) external view returns (uint) {
        return userStakeInfo[_user].amount;
    }
}

interface IReferral {
    function hasReferrer(address user) external view returns (bool);
    function isLocked(address user) external view returns (bool);
    function lockAddress(address user) external;
    function setReferrer(address referrer) external;
    function getReferrer(address user) external view returns (address);
    function getReferredUsers(address referrer) external view returns (address[] memory) ;
}

contract PredictionReferral is IReferral, Ownable {
    //map of referred user to the their referrer
    mapping(address => address) public userReferrer; 
    //map of a user to an array of all users referred by them
    mapping(address => address[]) public referredUsers; 
    mapping(address => bool) public userExistence;
    mapping(address => bool) public userLocked;
    uint public referrerCount;
    uint public referredCount;
    address public factoryAddress;

    event PredictionsReferralEnable(address indexed user);
    event PredictionsSetReferrer(address indexed user, address indexed referrer);

    //set factory address that will send lock command
    function setFactory(address _factoryAddress) external onlyOwner {
        factoryAddress = _factoryAddress;
    }

    //address can only be locked from the factory contract
    function lockAddress(address user) override external {
        require(msg.sender == factoryAddress, "You dont have the permission to lock.");
        userLocked[user] = true;
    }

    function enableAddress() external {
        require(!userExistence[msg.sender], "This address is already enabled");
        userExistence[msg.sender] = true;

        emit PredictionsReferralEnable(msg.sender);
    }

    function setReferrer(address referrer) override external {
        require(userReferrer[msg.sender] == address(0), "You already have a referrer.");
        require(!userLocked[msg.sender], "You can not set a referrer after making a bet.");
        require(msg.sender != referrer, "You can not refer your own address.");
        require(userExistence[referrer], "The referrer address is not in the system.");
        userReferrer[msg.sender] = referrer;
        userLocked[msg.sender] = true;
        referredCount++;
        if(referredUsers[referrer].length == 0){
            referrerCount++;
        }
        referredUsers[referrer].push(msg.sender);

        emit PredictionsSetReferrer(msg.sender, referrer);
    }

    //GET FUNCTIONS

    function hasReferrer(address user) override external view virtual returns (bool) {
        return userReferrer[user] != address(0);
    }

    function isLocked(address user) override external view virtual returns (bool) {
        return userLocked[user];
    }

    function getReferrer(address user) override external view returns (address) {
        return userReferrer[user];
    }

    function getReferredUsers(address referrer) override external view returns (address[] memory) {
        return referredUsers[referrer];
    }
}

contract PredictionFactory is Ownable {
    uint256 public predictionCount;
    address public adminAddress;
    address public operatorAddress;

    mapping(uint256 => Prediction) public predictions;
    mapping(uint256 => IERC20) public betTokens;
 
    IReferral public referralSystem;
    IStaker public staker;

    constructor(
        address _adminAddress,
        address _operatorAddress,
        address _referralSystemAddress,
        address _stakerSystemAddress
    ) {
        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
        referralSystem = IReferral(_referralSystemAddress);
        staker = IStaker(_stakerSystemAddress);
    }

    function createPrediction(
        AggregatorV3Interface _oracle,
        uint32 _intervalSeconds,
        uint32 _bufferSeconds,
        uint256 _minBetAmount,
        uint256 _oracleUpdateAllowance,
        IERC20 _betToken,
        uint256 _treasuryRate,
        uint256 _referrerRate,
        uint256 _refereeRate
    ) external onlyAdmin {
        Prediction pred = new Prediction();
        pred.initialize(
            _oracle,
            _intervalSeconds,
            _bufferSeconds,
            _minBetAmount,
            _oracleUpdateAllowance,
            _betToken,
            _treasuryRate, 
            _referrerRate,    
            _refereeRate,   
            address(referralSystem),
            address(staker)
        );

        betTokens[predictionCount] = _betToken;
        predictions[predictionCount++] = pred;
    }

    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "no contract");
        require(msg.sender == tx.origin, "no proxy contract");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "adm");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "op");
        _;
    }

    modifier onlyAdminOrOperator() {
        require(msg.sender == adminAddress || msg.sender == operatorAddress, "adm|op");
        _;
    }

    /**
     * @dev set admin address
     * callable by owner
     */
    function setAdmin(address _adminAddress) external onlyOwner {
        require(_adminAddress != address(0));
        adminAddress = _adminAddress;
    }

    /**
     * @dev set operator address
     * callable by admin
     */
    function setOperator(address _operatorAddress) external onlyAdmin {
        require(_operatorAddress != address(0));
        operatorAddress = _operatorAddress;
    }

    /**
     * @dev set interval Seconds
     * callable by admin
     */
    function setIntervalSeconds(uint256 _index, uint32 _intervalSeconds) external onlyAdmin {
        predictions[_index].setIntervalSeconds(_intervalSeconds);
    }

    /**
     * @dev set buffer Seconds
     * callable by admin
     */
    function setBufferSeconds(uint256 _index, uint32 _bufferSeconds) external onlyAdmin {
        predictions[_index].setBufferSeconds(_bufferSeconds);
    }

    /**
     * @dev set Oracle address
     * callable by admin
     */
    function setOracle(uint256 _index, address _oracle) external onlyAdmin {
        predictions[_index].setOracle(_oracle);
    }

    /**
     * @dev set oracle update allowance
     * callable by admin
     */
    function setOracleUpdateAllowance(uint256 _index, uint256 _oracleUpdateAllowance) external onlyAdmin {
        predictions[_index].setOracleUpdateAllowance(_oracleUpdateAllowance);
    }

    /**
     * @dev set treasury rate
     * callable by admin
     */
    function setTreasuryRate(uint256 _index, uint256 _treasuryRate) external onlyAdmin {
        predictions[_index].setTreasuryRate(_treasuryRate);
    }


    function setMinBetAmount(uint256 _index, uint256 _minBetAmount) external onlyAdmin {
        predictions[_index].setMinBetAmount(_minBetAmount);
    }

    /**
     * @dev Start genesis round
     */
    function genesisStartRound(uint256 _index) external onlyOperator {
        predictions[_index].genesisStartRound();
    }

    /**
     * @dev Lock genesis round
     */
    function genesisLockRound(uint256 _index) external onlyOperator {
        predictions[_index].genesisLockRound();
    }

    /**
     * @dev Start the next round n, lock price for round n-1, end round n-2
     */
    function executeRound(uint256 _index) external onlyOperator {
        predictions[_index].executeRound();
    }

    /**
     * @dev Bet bear position
     */
    function betBear(uint256 _index, uint256 epoch, uint256 amount) external notContract {
        Prediction pred = predictions[_index];
        IERC20 betToken = betTokens[_index];
        betToken.transferFrom(msg.sender, address(pred), amount);
        pred.betBear(epoch, msg.sender, amount);
        if(!referralSystem.isLocked(msg.sender))
        {
            referralSystem.lockAddress(msg.sender);
        }
    }

    /**
     * @dev Bet bull position
     */
    function betBull(uint256 _index, uint256 epoch, uint256 amount) external notContract {
        Prediction pred = predictions[_index];
        IERC20 betToken = betTokens[_index];
        betToken.transferFrom(msg.sender, address(pred), amount);
        pred.betBull(epoch, msg.sender, amount);
        if(!referralSystem.isLocked(msg.sender))
        {
            referralSystem.lockAddress(msg.sender);
        }
    }

    function claimAllPredictions(uint256[] calldata indeces, uint256[][] calldata epochs) external notContract {
        for (uint256 i = 0; i < indeces.length; i++) {
            predictions[indeces[i]].claim(msg.sender, epochs[i]);
        }
    }

    function claim(uint256 _index, uint256[] calldata epochs) external notContract {
        predictions[_index].claim(msg.sender, epochs);
    }

    function claimAllReferenceBonuses(uint256[] calldata indeces) external notContract {
        for (uint256 i = 0; i < indeces.length; i++) {
            predictions[indeces[i]].claimReferenceBonus(msg.sender);
        }
    }

    function claimReferenceBonus(uint256 _index) external notContract {
        predictions[_index].claimReferenceBonus(msg.sender);
    }

    /**
     * @dev Claim all rewards in treasury
     * callable by admin
     */
    function claimTreasury(uint256 _index) external onlyAdmin {
        predictions[_index].claimTreasury(adminAddress);
    }

    /**
     * @dev called by the admin to pause, triggers stopped state
     */
    function pause(uint256 _index) external onlyAdminOrOperator {
        predictions[_index].pause();
    }

    /**
     * @dev called by the admin to unpause, returns to normal state
     */
    function unpause(uint256 _index) external onlyAdminOrOperator {
        predictions[_index].unpause();
    }

     /**
     * @dev It allows the owner to recover tokens sent to the contract by mistake
     */
    function recoverToken(uint256 _index, address _token, uint256 _amount) external onlyAdmin {
        predictions[_index].recoverToken(_token, _amount, msg.sender);
    }

    // Read Functions

    /**
     * @dev Get the claimable stats of specific epoch and user account
     */
    function claimable(uint256 _index, uint256 epoch, address user) external view returns (bool) {
        return predictions[_index].claimable(epoch, user);
    }

    /**
     * @dev Get the refundable stats of specific epoch and user account
     */
    function refundable(uint256 _index, uint256 epoch, address user) external view returns (bool) {
        return predictions[_index].refundable(epoch, user);
    }

    /**
     * @dev Get the oracle address for the specified prediction
     */
    function getOracleInfo(uint256 _index) external view returns (address) {
        return predictions[_index].oracleInfo();
    }


    //STAKING AND REFERENCE SYSTEM FUNCTIONS

    function setStaker(address _stakerAddress) external onlyAdmin {
        staker = IStaker(_stakerAddress);
        for (uint256 i = 0; i < predictionCount; i++) {
            predictions[i].setStaker(_stakerAddress);
        }
    }

    function setStakingLevelBonuses(uint256 _index, uint256[] calldata _bonuses) external onlyAdmin {
        predictions[_index].setStakingLevelBonuses(_bonuses);
    }

    function setReferralSystem(address _referralSystemAddress) external onlyAdmin {
        referralSystem = IReferral(_referralSystemAddress);
        for (uint256 i = 0; i < predictionCount; i++) {
            predictions[i].setReferralSystem(_referralSystemAddress);
        }
    }

    function setReferralRates(uint256 _index, uint256 _referrerRate, uint256 _refereeRate) external onlyAdmin {
        predictions[_index].setReferralRates(_referrerRate, _refereeRate);
    }
}