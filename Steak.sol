// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./HotPotato.sol";
import "./NFTRouter.sol";

contract Steak is ERC20 {

  address private _owner;
  address private _hptAddress;
  address private _finisherAddress;

  mapping (address => bool) private _managers;

  mapping (uint256 => uint256) private _epochStakes;
  mapping (address => uint256) private _stakeEpoch;
  mapping (address => bool) private _isStaked;
  mapping (uint256 => mapping(address => uint256)) private _epochContributingStakes;

  address private _nftRouterAddress;

  mapping (address => bool) private _avoidClear;

  event Stake(
    address account,
    uint256 amount,
    uint256 epoch,
    uint256 timestamp
  );

  event Unstake(
    address account,
    uint256 amount,
    uint256 epoch,
    uint256 timestamp
  );
  
  constructor() ERC20("Steak", "STK") {
    _owner = msg.sender;
  }

  function addManager(address _account) public {
    require(msg.sender == _owner);
    _managers[_account] = true;
  }

  function removeManager(address _account) public {
    require(msg.sender == _owner);
    _managers[_account] = false;
  }

  function setHPT(address hptAddress_) public {
    require(msg.sender == _owner, "Steak: Only the contract owner can set the HPT address");
    _hptAddress = hptAddress_;
  }

  function setFinisher(address finisherAddress_) public {
    require(msg.sender == _owner, "Steak: Only the contract owner can set the finisher address");
    _finisherAddress = finisherAddress_;
  }

  function setNFTRouterAddress(address nftRouterAddress_) public {
    require(msg.sender == _owner);
    _nftRouterAddress = nftRouterAddress_;
  }

  function nftRouter() private view returns (NFTRouter) {
    return NFTRouter(_nftRouterAddress);
  }

  function enter(address account, uint256 amount, uint256 epoch) public {
    require(msg.sender == _hptAddress, "Steak: Only the HPT contract can call enter");
    _avoidClear[account] = true;
    _mint(account, amount);
    increaseEpochStakes(epoch, amount);
    increaseEpochContribution(account, epoch, amount);
    _avoidClear[account] = false;
    
    emit Stake(account, amount, epoch, block.timestamp);
  }

  function exit(address account, uint256 amount, uint256 epoch) public {
    require(msg.sender == _hptAddress, "Steak: Only the HPT contract can call exit");

    _avoidClear[account] = true;
    _burn(account, amount);
    
    reduceEpochContribution(account, epoch, amount);

    if (balanceOf(account) == 0) {
      setUnstaked(account);
    }
    _avoidClear[account] = false;

    nftRouter().burnCurrentCard(account, 2);

    emit Unstake(account, amount, epoch, block.timestamp);
  }

  function mint(address account, uint256 amount) public  {
    require(msg.sender == _hptAddress || msg.sender == _finisherAddress, "Steak: Only the HPT contract can call mint");
    _avoidClear[account] = true;
    _mint(account, amount);
    _avoidClear[account] = false;
  }

  function airdrop(address account, uint256 amount) public {
    require(msg.sender == _owner);

    HotPotato hotPotato = HotPotato(_hptAddress);
    require(hotPotato.getCurrentEpoch() <= 50);

    _mint(account, amount);
  }

  function getEpochStakedIn(address account) public view returns (uint256) {
    return _stakeEpoch[account];
  }

  function getEpochStakes(uint256 epoch) public view returns (uint256) {
    return _epochStakes[epoch];
  }

  function isStaked(address account) public view returns (bool) {
    return _isStaked[account];
  }

  function getEpochContribution(address account, uint256 epoch) public view returns (uint256) {
    return _epochContributingStakes[epoch][account];
  }

  function setStaked(address account, uint256 epoch) public {
    require(msg.sender == _hptAddress, "Steak: Only the HPT contract can call setStaked");
    _stakeEpoch[account] = epoch;
    _isStaked[account] = true;
  }

  function setUnstaked(address account) private {
    _stakeEpoch[account] = 0;
    _isStaked[account] = false;
  }

  function increaseEpochStakes(uint256 epoch, uint256 amount) public {
    require(msg.sender == _hptAddress, "Steak: Only the HPT contract can call increaseEpochStakes");
    _epochStakes[epoch] += amount;
  }

  function reduceEpochStakes(uint256 epoch, uint256 amount) private {
    if (_epochStakes[epoch] > amount) {
      _epochStakes[epoch] -= amount;
    } else {
      _epochStakes[epoch] = 0;
    }
  }

  function increaseEpochContribution(address account, uint256 epoch, uint256 amount) private {
    _epochContributingStakes[epoch][account] += amount;
  }

  function reduceEpochContribution(address account, uint256 epoch, uint256 amount) private {
    HotPotato hotPotato = HotPotato(_hptAddress);

    if (getEpochContribution(account, epoch) > amount) {
      _epochContributingStakes[epoch][account] -= amount;
    } else {
      _epochContributingStakes[epoch][account] = 0;
    }

    if (hotPotato.getCurrentEpoch() == epoch) {
      reduceEpochStakes(epoch, amount);
    }
  }

  function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    if (!_avoidClear[from]) {
      clearStakingRewards(from);
    }
  }

  function clearStakingRewards(address _account) private {
    uint256 epoch = _stakeEpoch[_account];
    
    uint256 epochContribution = _epochContributingStakes[epoch][_account];

    reduceEpochContribution(_account, epoch, epochContribution);

    setUnstaked(_account);
  }

  function decayRate(uint256 stakeEpoch, uint256 currentEpoch) public pure returns (uint256) {
    if (stakeEpoch == 0) {
      return 0;
    } else {
      uint256 remainder = currentEpoch - stakeEpoch;
      if (remainder <= 1) {
        return 0;
      } else if (remainder < 12) {
        return (remainder - 1) * 10;
      } else {
        return 100;
      }
    }
  }

  function stakingReward(
    address account, 
    uint256 currentEpoch, 
    uint256 deposits, 
    uint256 slashFactor, 
    uint256 rewardRate
  ) public view returns (uint256) {
    uint256 stakeEpoch = getEpochStakedIn(account);

    uint256 bonus = 1;

    if (nftRouter().getCurrentAbilityKind(account) == 2) {
      bonus = nftRouter().getCurrentAbilityAmount(account);
    }

    if (stakeEpoch > 0) {

      uint256 epochIndex = stakeEpoch;
      if (epochIndex == currentEpoch) {
        return 0;
      } else {
        uint256 totalStaked = getEpochStakes(epochIndex);
        uint256 accountStake = getEpochContribution(account, epochIndex);

        if (totalStaked == 0 || (accountStake > totalStaked)) {
          return 0;
        } else {
          uint256 remainder = deposits - (deposits / slashFactor);

          uint256 reward = (remainder * accountStake * rewardRate) / (100 * totalStaked);

          reward = (reward - ((reward * decayRate(epochIndex, currentEpoch)) / 100));

          return bonus * reward;
        }
      }
    } else {
      return 0;
    }
  }

  function burn(address account, uint256 amount) public {
    require((msg.sender == _owner) || _managers[msg.sender]);
    _burn(account, amount);
  }

}
