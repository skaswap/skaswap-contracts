// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./ISkaERC20.sol";

contract SkaVault is Ownable, ReentrancyGuard {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp; // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        uint256 lastInteraction; // Last time when user deposited or claimed rewards, renewing the lock
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract
        uint256 allocPoint; // How many allocation points assigned to this pool. Ska to distribute per block.
        uint256 lastRewardBlock; // Last block number that Ska distribution occurs.
        uint256 accSkaPerShare; // Accumulated Ska per share, times 1e12. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
        uint256 harvestInterval; // Harvest interval in seconds
        uint256 totalLp; // Total token in Pool
        uint256 lockupDuration; // Amount of time the participant will be locked in the pool after depositing or claiming rewards
    }

    ISkaERC20 public ska;

    // The operator can only update EmissionRate and AllocPoint to protect tokenomics
    //i.e some wrong setting and a pools get too much allocation accidentally
    address private _operator;

    // Dev address.
    address public devAddress;

    // Deposit Fee address
    address public feeAddress;

    // Ska tokens created per block
    uint256 public skaPerBlock;

    // Max harvest interval: 14 days
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Maximum deposit fee rate: 10%
    uint16 public constant MAXIMUM_DEPOSIT_FEE_RATE = 1000;

    // Info of each pool
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The block number when Ska mining starts.
    uint256 public startBlock;

    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Total Ska in Ska Pools (can be multiple pools)
    uint256 public totalSkaInPools = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event EmissionRateUpdated(
        address indexed caller,
        uint256 previousAmount,
        uint256 newAmount
    );
    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );
    event OperatorTransferred(
        address indexed previousOperator,
        address indexed newOperator
    );
    event DevAddressChanged(
        address indexed caller,
        address oldAddress,
        address newAddress
    );
    event FeeAddressChanged(
        address indexed caller,
        address oldAddress,
        address newAddress
    );
    event AllocPointsUpdated(
        address indexed caller,
        uint256 previousAmount,
        uint256 newAmount
    );

    modifier onlyOperator() {
        require(
            _operator == msg.sender,
            "Operator: caller is not the operator"
        );
        _;
    }

    constructor(ISkaERC20 _ska, uint256 _skaPerBlock) {
        //StartBlock always many years later from contract construct, will be set later in StartFarming function
        startBlock = block.number + (10 * 365 * 24 * 60 * 60);

        ska = _ska;
        skaPerBlock = _skaPerBlock;

        devAddress = msg.sender;
        feeAddress = msg.sender;
        _operator = msg.sender;
        emit OperatorTransferred(address(0), _operator);
    }

    function operator() public view returns (address) {
        return _operator;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        pure
        returns (uint256)
    {
        return _to.sub(_from);
    }

    function transferOperator(address newOperator) public onlyOperator {
        require(
            newOperator != address(0),
            "TransferOperator: new operator is the zero address"
        );
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }

    // Set farming start, can call only once
    function startFarming() public onlyOwner {
        require(block.number < startBlock, "Error: farm started already");

        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardBlock = block.number;
        }

        startBlock = block.number;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // Can add multiple pool with same lp token without messing up rewards, because each pool's balance is tracked using its own totalLp
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _depositFeeBP,
        uint256 _harvestInterval,
        uint256 _lockupDuration
    ) public onlyOwner {
        require(
            _depositFeeBP <= MAXIMUM_DEPOSIT_FEE_RATE,
            "Add: deposit fee too high"
        );
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "Add: invalid harvest interval"
        );
        massUpdatePools();
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accSkaPerShare: 0,
                depositFeeBP: _depositFeeBP,
                harvestInterval: _harvestInterval,
                totalLp: 0,
                lockupDuration: _lockupDuration
            })
        );
    }

    // View function to see pending Ska on frontend.
    function pendingSka(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSkaPerShare = pool.accSkaPerShare;
        uint256 lpSupply = pool.totalLp;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 skaReward = multiplier
                .mul(skaPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accSkaPerShare = accSkaPerShare.add(
                skaReward.mul(1e12).div(lpSupply)
            );
        }

        uint256 pending = user.amount.mul(accSkaPerShare).div(1e12).sub(
            user.rewardDebt
        );
        return pending.add(user.rewardLockedUp);
    }

    // View function to see when user will be unlocked from pool
    function userLockedUntil(uint256 _pid, address _user)
        public
        view
        returns (uint256)
    {
        UserInfo storage user = userInfo[_pid][_user];
        PoolInfo storage pool = poolInfo[_pid];

        return user.lastInteraction + pool.lockupDuration;
    }

    // View function to see if user can harvest Ska.
    function canHarvest(uint256 _pid, address _user)
        public
        view
        returns (bool)
    {
        UserInfo storage user = userInfo[_pid][_user];
        return
            block.number >= startBlock &&
            block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint256 lpSupply = pool.totalLp;
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 skaReward = multiplier
            .mul(skaPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);

        ska.mint(devAddress, skaReward.div(10));
        ska.mint(address(this), skaReward);

        pool.accSkaPerShare = pool.accSkaPerShare.add(
            skaReward.mul(1e12).div(pool.totalLp)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to SkaVault for Ska allocation
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        require(
            block.number >= startBlock,
            "SkaVault: cannot deposit before farming start"
        );

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        updatePool(_pid);

        payOrLockupPendingSka(_pid);

        if (_amount > 0) {
            uint256 beforeDeposit = pool.lpToken.balanceOf(address(this));
            pool.lpToken.safeTransferFrom(_msgSender(), address(this), _amount);
            uint256 afterDeposit = pool.lpToken.balanceOf(address(this));

            _amount = afterDeposit.sub(beforeDeposit);

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);

                _amount = _amount.sub(depositFee);
            }

            user.amount = user.amount.add(_amount);
            pool.totalLp = pool.totalLp.add(_amount);

            if (address(pool.lpToken) == address(ska)) {
                totalSkaInPools = totalSkaInPools.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accSkaPerShare).div(1e12);
        user.lastInteraction = block.timestamp;
        emit Deposit(_msgSender(), _pid, _amount);
    }

    // Withdraw tokens
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        //this will make sure that user can only withdraw from his pool
        require(user.amount >= _amount, "Withdraw: user amount is not enough");

        //Cannot withdraw more than pool's balance
        require(pool.totalLp >= _amount, "Withdraw: pool total is not enough");

        //Cannot withdraw before lock time
        require(
            block.timestamp > user.lastInteraction + pool.lockupDuration,
            "Withdraw: you cannot withdraw yet"
        );

        updatePool(_pid);

        payOrLockupPendingSka(_pid);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalLp = pool.totalLp.sub(_amount);
            if (address(pool.lpToken) == address(ska)) {
                totalSkaInPools = totalSkaInPools.sub(_amount);
            }
            pool.lpToken.safeTransfer(_msgSender(), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSkaPerShare).div(1e12);
        user.lastInteraction = block.timestamp;
        emit Withdraw(_msgSender(), _pid, _amount);
    }

    // Pay or lockup pending Ska.
    function payOrLockupPendingSka(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];

        if (user.nextHarvestUntil == 0 && block.number >= startBlock) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accSkaPerShare).div(1e12).sub(
            user.rewardDebt
        );
        if (canHarvest(_pid, _msgSender())) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(
                    user.rewardLockedUp
                );
                user.rewardLockedUp = 0;
                user.lastInteraction = block.timestamp;
                user.nextHarvestUntil = block.timestamp.add(
                    pool.harvestInterval
                );

                // send rewards
                safeSkaTransfer(_msgSender(), totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            user.lastInteraction = block.timestamp;
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(_msgSender(), _pid, pending);
        }
    }

    // Safe Ska transfer function, just in case if rounding error causes pool do not have enough Ska.
    function safeSkaTransfer(address _to, uint256 _amount) internal {
        if (ska.balanceOf(address(this)) > totalSkaInPools) {
            //SkaBal = total Ska in SkaVault - total Ska in Ska pools, this will make sure that SkaVault never transfer rewards from deposited Ska pools
            uint256 SkaBal = ska.balanceOf(address(this)).sub(
                totalSkaInPools
            );
            if (_amount >= SkaBal) {
                ska.transfer(_to, SkaBal);
            } else if (_amount > 0) {
                ska.transfer(_to, _amount);
            }
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(_msgSender() == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");

        emit DevAddressChanged(_msgSender(), devAddress, _devAddress);

        devAddress = _devAddress;
    }

    function setFeeAddress(address _feeAddress) public {
        require(_msgSender() == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");

        emit FeeAddressChanged(_msgSender(), feeAddress, _feeAddress);

        feeAddress = _feeAddress;
    }

    // Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _skaPerBlock) public onlyOperator {
        massUpdatePools();

        emit EmissionRateUpdated(msg.sender, skaPerBlock, _skaPerBlock);
        skaPerBlock = _skaPerBlock;
    }

    function updateAllocPoint(
        uint256 _pid,
        uint256 _allocPoint
    ) public onlyOperator {

        massUpdatePools();

        emit AllocPointsUpdated(
            _msgSender(),
            poolInfo[_pid].allocPoint,
            _allocPoint
        );

        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

}
