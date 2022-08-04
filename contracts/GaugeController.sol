// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@pooltogether/owner-manager-contracts/contracts/Manageable.sol";

import "./interfaces/IGaugeController.sol";
import "./interfaces/IGaugeReward.sol";
import "./libraries/TwabLib.sol";
import "./libraries/ExtendedSafeCastLib.sol";

contract GaugeController is IGaugeController, Manageable {
    using ExtendedSafeCastLib for uint256;

    struct GaugeInfo {
        uint256 weight;
    }

    /// @notice ERC20 token contract address (used to weight gauges)
    IERC20 public token;

    /// @notice GaugeReward for stakers rewards/incentives
    IGaugeReward public gaugeReward;

    /**
      * @notice Tracks user balance. Balance is used to update target gauge weight balances.
      * @dev    The balance is updated in deposit, withthdraw, gaugeIncrease and gaugeDecrease.
    -----------------------------
    | Address     | Balance     |
    | ----------- | ----------- |
    | 0x111...111 | 0x1000      |
    | 0x222...222 | 0x100000    |
    -----------------------------
    */
    mapping(address => uint256) public balances;

    /**
      * @notice Tracks User => Gauge => balance.
      * @dev    The balance is updated in gaugeIncrease and gaugeDecrease.
    ----------------------------------------------
    | User        	| Gauge       	| Balance 	|
    |-------------	|-------------	|---------	|
    | 0x111...111 	| 0x999...999 	| 0x10000  	|
    | 0x111...111 	| 0x999...999 	| 0x30000 	|
    | 0x111...111 	| 0x999...999 	| 0x50000  	|
    ----------------------------------------------
    */
    mapping(address => mapping(address => uint256)) public userGaugeBalance;

    /**
      * @notice Tracks user rewards for staking.
      * @dev    The rewards is updated in
    -----------------------------
    | Address     | Rewards     |
    | ----------- | ----------- |
    | 0x111...111 | 0x100000    |
    | 0x222...222 | 0x500000    |
    -----------------------------
    */
    mapping(address => uint256) public rewards;

    /// @notice User balances staked in existing Gauge.
    mapping(address => TwabLib.Account) internal gaugeTwabs;

    /// @notice Governance scale set for existing Gauge.
    mapping(address => TwabLib.Account) internal gaugeScaleTwabs;

    /**
     * @notice Event emitted when the contract is deployed
     * @param token Address of the token being staked in the gauge
     * @param owner Address of the contract owner
     */
    event Deployed(IERC20 token, address owner);

    /**
     * @notice Emitted when GaugeReward address is set/updated
     * @param gaugeReward Address of the newly set GaugeReward contract
     */
    event GaugeRewardSet(IGaugeReward gaugeReward);

    /**
     * @notice Emitted when User deposits 'token' into the gauge.
     * @param user Address of the user who deposited 'token' into the GaugeController
     * @param amount Amount of 'token' deposited into the GaugeController
     */
    event TokenDeposited(address indexed user, uint256 amount);

    /**
     * @notice Emitted when User withdraws 'token' from the gauge.
     * @param user Address of the user who withdrew 'token' from the GaugeController
     * @param amount Amount of 'token' withdrawn from the GaugeController
     */
    event TokenWithdrawn(address indexed user, uint256 amount);

    /**
     * @notice Emitted when User increases a Gauge weight.
     * @param user User address
     * @param gauge Existing Gauge address
     * @param amount Amount of 'balance' debited from the User and credited to the Gauge
     */
    event GaugeIncreased(address indexed user, address indexed gauge, uint256 amount);

    /**
     * @notice Emitted when User decrease a Gauge weight.
     * @param user User address
     * @param gauge Existing Gauge address
     * @param amount Amount of 'balance' debited from the Gauge and credited to the User
     */
    event GaugeDecreased(address indexed user, address indexed gauge, uint256 amount);

    /**
     * @notice Emitted when an Authorized User adds a new Gauge to the GaugeController
     * @param user Authorized address
     * @param gauge New Gauge address
     */
    event GaugeAdded(address indexed user, address gauge);

    /**
     * @notice Emitted when an Authorized User removes an existing Gauge from the GaugeController
     * @param user Authorized address
     * @param gauge Gauge address
     */
    event GaugeRemoved(address indexed user, address indexed gauge);

    /**
     * @notice Emitted when an Authorized User sets an existing Gauge 'scale' weight.
     * @param user Authorized address
     * @param gauge Gauge address
     * @param scale New Gauge scale
     * @param oldScale Old Gauge scale
     */
    event GaugeScaleSet(
        address indexed user,
        address indexed gauge,
        uint256 scale,
        uint256 oldScale
    );

    /* ================================================================================ */
    /* Constructor & Modifiers                                                          */
    /* ================================================================================ */

    /**
     * @notice GaugeController Construction
     * @param _token ERC20 contract address (used to weight gauges)
     * @param _owner Address of authorized owner
     */
    constructor(IERC20 _token, address _owner) Ownable(_owner) {
        require(_owner != address(0), "GC/owner-not-zero-address");
        require(address(_token) != address(0), "GC/token-not-zero-address");
        token = _token;

        emit Deployed(_token, _owner);
    }

    /**
     * @notice Modifier to check Gauge status.
     * @dev True if gauge is active. False otherwise.
     * @dev Modifier is RUN before the inheriting function is executed.
     * @param _gauge Gauge address to check.
     */
    modifier requireGauge(address _gauge) {
        require(isGauge(_gauge), "GaugeController:invalid-address");
        _;
    }

    /* ================================================================================ */
    /* External Functions                                                               */
    /* ================================================================================ */

    /**
     * @notice Checks gauge status by reading the TWAB balance
     * @dev Only reliable to check if a Gauge has been created AND also staked on.
     * @dev Uses the TWAB balance to determine "isGauge" status.
     * @param _gauge Gauge address to check.
     * @return True if gauge is active. False otherwise.
     */
    function isGauge(address _gauge) public view returns (bool) {
        return gaugeScaleTwabs[_gauge].details.balance > 0;
    }

    /**
     * @notice Deposit tokens in GaugeController and increase User balance.
     * @param _to  Receivzer of the deposited tokens
     * @param _amount  Amount of tokens to be deposited
     */
    function deposit(address _to, uint256 _amount) external {
        balances[_to] += _amount;
        token.transferFrom(msg.sender, address(this), _amount);
        emit TokenDeposited(msg.sender, _amount);
    }

    /**
     * @notice Withdraw tokens in GaugeController and increase User balance.
     * @param _amount  Amount of tokens to be withdrawn
     */
    function withdraw(uint256 _amount) external {
        balances[msg.sender] -= _amount;
        token.transfer(msg.sender, _amount);
        emit TokenWithdrawn(msg.sender, _amount);
    }

    /**
     * @notice Increase Gauge balance by decreasing User staked balance.
     * @param _gauge  Address of the Gauge
     * @param _amount Amount of tokens to be debited from the User balance and credited to the Gauge balance
     */
    function increaseGauge(address _gauge, uint256 _amount) external requireGauge(_gauge) {
        balances[msg.sender] -= _amount;
        userGaugeBalance[msg.sender][_gauge] += _amount;
        TwabLib.Account storage gaugeTwab = gaugeTwabs[_gauge];
        (TwabLib.AccountDetails memory twabDetails, , ) = TwabLib.increaseBalance(
            gaugeTwab,
            _amount.toUint208(),
            uint32(block.timestamp)
        );
        gaugeTwab.details = twabDetails;
        gaugeReward.afterIncreaseGauge(_gauge, msg.sender, uint256(twabDetails.balance) - _amount);
        emit GaugeIncreased(msg.sender, _gauge, _amount);
    }

    /**
     * @notice Decrease Gauge balance and increase User staked balance.
     * @param _gauge  Address of the Gauge
     * @param _amount Amount of tokens to be debited from the Gauge balance and credited to the Gauge balance
     */
    function decreaseGauge(address _gauge, uint256 _amount) external requireGauge(_gauge) {
        balances[msg.sender] += _amount;
        userGaugeBalance[msg.sender][_gauge] -= _amount;
        TwabLib.Account storage gaugeTwab = gaugeTwabs[_gauge];
        (TwabLib.AccountDetails memory twabDetails, , ) = TwabLib.decreaseBalance(
            gaugeTwab,
            _amount.toUint208(),
            "insuff",
            uint32(block.timestamp)
        );
        gaugeTwab.details = twabDetails;
        gaugeReward.afterDecreaseGauge(_gauge, msg.sender, uint256(twabDetails.balance) + _amount);
        emit GaugeDecreased(msg.sender, _gauge, _amount);
    }

    /**
     * @notice Add new gauge with "1e18" scale to the GaugeController.
     * @param _gauge Address of the Gauge
     */
    function addGauge(address _gauge) external onlyOwner {
        _addGaugeWithScale(_gauge, 1 ether);
    }

    /**
     * @notice Add new gauge and target scale to the GaugeController.
     * @param _gauge Address of new Gauge
     * @param _scale Amount to scale new Gauge by
     */
    function addGaugeWithScale(address _gauge, uint256 _scale) external onlyOwner {
        _addGaugeWithScale(_gauge, _scale);
    }

    /**
     * @notice Remove gauge from the GaugeController.
     * @param _gauge Address of existing Gauge
     */
    function removeGauge(address _gauge) external onlyOwner {
        TwabLib.Account storage gaugeScaleTwab = gaugeScaleTwabs[_gauge];
        TwabLib.AccountDetails memory twabDetails = gaugeScaleTwab.details;
        (twabDetails, , ) = TwabLib.decreaseBalance(
            gaugeScaleTwab,
            twabDetails.balance,
            "insuff",
            uint32(block.timestamp)
        );
        gaugeScaleTwab.details = twabDetails;
        emit GaugeRemoved(msg.sender, _gauge);
    }

    /**
     * @notice Set GaugeReward contract
     * @param _gaugeReward Address of the GaugeReward contract
     */
    function setGaugeReward(IGaugeReward _gaugeReward) external onlyManagerOrOwner {
        require(address(_gaugeReward) != address(0), "GC/GaugeReward-not-zero-address");
        gaugeReward = _gaugeReward;
        emit GaugeRewardSet(_gaugeReward);
    }

    /**
     * @notice Set Gauge target scale.
     * @param _gauge Address of existing Gauge
     * @param _scale Amount to scale existing Gauge by
     */
    function setGaugeScale(address _gauge, uint256 _scale) external onlyManagerOrOwner {
        TwabLib.Account storage gaugeScaleTwab = gaugeScaleTwabs[_gauge];
        TwabLib.AccountDetails memory twabDetails = gaugeScaleTwab.details;
        if (twabDetails.balance > _scale) {
            (twabDetails, , ) = TwabLib.decreaseBalance(
                gaugeScaleTwab,
                twabDetails.balance - _scale.toUint208(),
                "insuff",
                uint32(block.timestamp)
            );
        } else {
            (twabDetails, , ) = TwabLib.increaseBalance(
                gaugeScaleTwab,
                _scale.toUint208() - twabDetails.balance,
                uint32(block.timestamp)
            );
        }
        gaugeScaleTwab.details = twabDetails;
        emit GaugeScaleSet(msg.sender, _gauge, _scale, twabDetails.balance);
    }

    /// @inheritdoc IGaugeController
    function getGaugeBalance(address _gauge) external view override returns (uint256) {
        return gaugeTwabs[_gauge].details.balance;
    }

    /// @inheritdoc IGaugeController
    function getGaugeScaleBalance(address _gauge) external view override returns (uint256) {
        return gaugeScaleTwabs[_gauge].details.balance;
    }

    /// @inheritdoc IGaugeController
    function getUserGaugeBalance(address _gauge, address _user)
        external
        view
        override
        returns (uint256)
    {
        return userGaugeBalance[_user][_gauge];
    }

    /**
     * @notice Calculate Gauge weighted balance using Staked AND Scaled time-weighted average balances.
     * @param _gauge Address of existing Gauge
     * @param _startTime Unix timestamp to signal START of the Binary search
     * @param _endTime Unix timestamp to signal END of the Binary search
     * @return uint256 Weighted(Staked * Scaled) Gauge Balance
     */
    function getScaledAverageGaugeBalanceBetween(
        address _gauge,
        uint256 _startTime,
        uint256 _endTime
    ) external view override returns (uint256) {
        uint256 gauge = _getAverageGaugeBalanceBetween(_gauge, _startTime, _endTime);
        uint256 gaugeScale = _getAverageGaugeScaleBetween(_gauge, _startTime, _endTime);
        return (gauge * gaugeScale) / 1 ether;
    }

    /**
     * @notice Calculate Gauge average balance between two timestamps.
     * @param _gauge Address of existing Gauge
     * @param _startTime Unix timestamp to signal START of the Binary search
     * @param _endTime Unix timestamp to signal END of the Binary search
     * @return uint256 Gauge average staked balance between two timestamps.
     */
    function getAverageGaugeBalanceBetween(
        address _gauge,
        uint256 _startTime,
        uint256 _endTime
    ) external view returns (uint256) {
        return _getAverageGaugeBalanceBetween(_gauge, _startTime, _endTime);
    }

    /**
     * @notice Calculate Gauge average scale between two timestamps.
     * @param _gauge Address of existing Gauge
     * @param _startTime Unix timestamp to signal START of the Binary search
     * @param _endTime Unix timestamp to signal END of the Binary search
     * @return uint256 Gauge average scaled balance between two timestamps.
     */
    function getAverageGaugeScaleBetween(
        address _gauge,
        uint256 _startTime,
        uint256 _endTime
    ) external view returns (uint256) {
        return _getAverageGaugeScaleBetween(_gauge, _startTime, _endTime);
    }

    /* ================================================================================ */
    /* Internal Functions                                                               */
    /* ================================================================================ */

    function _addGaugeWithScale(address _gauge, uint256 _scale) internal {
        TwabLib.Account storage gaugeScaleTwab = gaugeScaleTwabs[_gauge];
        (TwabLib.AccountDetails memory twabDetails, , ) = TwabLib.increaseBalance(
            gaugeScaleTwab,
            _scale.toUint208(),
            uint32(block.timestamp)
        );
        gaugeScaleTwab.details = twabDetails;
        emit GaugeAdded(msg.sender, _gauge);
    }

    function _getAverageGaugeBalanceBetween(
        address _gauge,
        uint256 _startTime,
        uint256 _endTime
    ) internal view returns (uint256) {
        TwabLib.AccountDetails memory gaugeDetails = gaugeTwabs[_gauge].details;
        return
            TwabLib.getAverageBalanceBetween(
                gaugeTwabs[_gauge].twabs,
                gaugeDetails,
                uint32(_startTime),
                uint32(_endTime),
                uint32(block.timestamp)
            );
    }

    function _getAverageGaugeScaleBetween(
        address _gauge,
        uint256 _startTime,
        uint256 _endTime
    ) internal view returns (uint256) {
        TwabLib.AccountDetails memory gaugeScaleDetails = gaugeScaleTwabs[_gauge].details;
        return
            TwabLib.getAverageBalanceBetween(
                gaugeScaleTwabs[_gauge].twabs,
                gaugeScaleDetails,
                uint32(_startTime),
                uint32(_endTime),
                uint32(block.timestamp)
            );
    }
}