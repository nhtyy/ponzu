// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;

import "./libraries/safemath.sol";
import "./libraries/IERC20.sol";
import "./libraries/yearnVault.sol";

// Special thanks to twiiter@prism0x for being way smarter than me with this distribution algo
// https://solmaz.io/2019/02/24/scalable-reward-changing/


/// @title PonzuVault :: Single asset token vault
/// @author Nuhhtyy
/// @notice Single asset vault, no liqudations synthetic self repaying over-collaterized loans
///         All Yeild Generated from Yearn Vaults
/// @dev 1% Fee taken via synth
contract pVault {

    using SafeMath for uint;

    // #########################
    // ##                     ##
    // ##       State         ##
    // ##                     ##
    // #########################

    // ENSURE COLLATERAL AND SYNTH TOKEN REVERTS ON FAILED TRANSFER
    IERC20 internal collateral;
    IERC20 internal synthetic;
    yVault internal yearnVault;
    address feeCollector;

    mapping (address => uint) public deposits;
    mapping (address => uint) public debt;

    uint256 public totalDebt;
    uint256 public totalDeposits;
    uint256 public totalYearnDeposited;
    uint256 public feesAccumlated;

    // sum of all distribution events ( yeild / totalDeposits )
    // scaled 1e10.. As long as rewards accumlated between distributions
    // are greater than 1/1e10 totalDeposits , distribute() should return a nonzero value
    uint256 internal yeildPerDeposit;
    uint256 internal SCALAR;

    // sum of changes of deposit * yeildPerToken
    mapping (address => uint) internal depositTracker;

    // Too bad using a uint16 in storage doesnt even save gas :(
    // Say I wont pack it into a struct I dare you
    // 75% BP
    uint16 maxLTV = 7500;

    // 1.25% BP ... Used to incentivize LPs
    uint16 fee = 125;

    constructor(address _synthetic, address _yearnVault, address _collateral, address _feeCollector) {
    
        yearnVault = yVault(_yearnVault);
        collateral = IERC20(_collateral);
        synthetic = IERC20(_synthetic);
        feeCollector = _feeCollector;
    }

    // #########################
    // ##                     ##
    // ##     External        ##
    // ##                     ##
    // #########################

    function deposit(uint amount) external {

        deposits[msg.sender] = deposits[msg.sender].add(amount);
        totalDeposits = totalDeposits.add(amount);

        // Im sorry this is ugly omg
        depositTracker[msg.sender] = 
            depositTracker[msg.sender]
                .add(yeildPerDeposit.mul(amount).div(SCALAR));
        
        uint depositing = amount.mul(5000).div(10000);
        totalYearnDeposited = totalYearnDeposited.add(depositing);

        // Make sure Collateral tokens Revert
        collateral.transferFrom(msg.sender, address(this), amount);

        // deposit 50% to yVault
        yearnVault.deposit(depositing);
    }   

    function withdraw(uint amount) external {

        require( withdrawable(msg.sender) >= amount, "Amount too high");
        deposits[msg.sender] = deposits[msg.sender].sub(amount);
        totalDeposits = totalDeposits.sub(amount);

        depositTracker[msg.sender] = 
            depositTracker[msg.sender]
                .sub(yeildPerDeposit.mul(amount).div(SCALAR));
        
        if ( amount > collateral.balanceOf(address(this)) ) {

            withdrawNeeded(amount);

        }

        collateral.transfer(msg.sender, amount);

    }

    function incurDebt(uint amount) external {

        require( debt[msg.sender].add(amount) <= deposits[msg.sender].mul(maxLTV).div(10000) );

        debt[msg.sender] = debt[msg.sender].add(amount);
        totalDebt = totalDebt.add(amount);

        uint feeAdjust = amount.mul(fee).div(10000);
        feesAccumlated = feesAccumlated.add( amount.sub(feeAdjust) );

        synthetic.mint(msg.sender, feeAdjust);

    }

    function repayDebtSynth(uint amount) external {

        require ( debt[msg.sender] >= amount );
        debt[msg.sender] = debt[msg.sender].sub(amount);
        totalDebt = totalDebt.sub(amount);

        synthetic.transferFrom(msg.sender, address(this), amount); //change to burn

    }

    function repayDebtAsset(uint amount) external {

        require ( debt[msg.sender] >= amount );
        debt[msg.sender] = debt[msg.sender].sub(amount);
        totalDebt = totalDebt.sub(amount);

        collateral.transferFrom(msg.sender, address(this), amount);

    }

    function claimFees() external {

        require(msg.sender == feeCollector);

        uint fees = feesAccumlated;
        feesAccumlated = 0;

        synthetic.mint(msg.sender, fees);

    } 

    // #########################
    // ##                     ##
    // ##       Public        ##
    // ##                     ##
    // #########################

    function harvestAndDistribute() public {

        uint yeild = getYeild();
        yearnVault.withdraw(yeild);

        yeildPerDeposit = yeildPerDeposit
            .add(yeild.mul(SCALAR).div(totalDeposits));

    }

    //does not change user debt or overall debt
    //Will likely change this somehow.. not sure yet
    function burnSynth(uint amount) public {
        
        totalDeposits = totalDeposits.sub(amount);

        synthetic.transferFrom(msg.sender, address(0), amount);
        collateral.transfer(msg.sender, amount);

    }

    // #########################
    // ##                     ##
    // ##     Internal        ##
    // ##                     ##
    // #########################

    function getYeild() internal returns (uint) {

        uint price = yearnVault.getPricePerFullShare();
        uint totalClaimable = yearnVault.balanceOf(address(this)).mul(price);

        return totalClaimable.sub(totalYearnDeposited);

    }

    function withdrawable(address who) internal view returns (uint) {

        uint yeild = deposits[who]
            .mul(yeildPerDeposit).div(SCALAR)
                .sub(depositTracker[msg.sender]);

        uint colSubDebt = deposits[who].sub(debt[who]);

        return colSubDebt.add(yeild);

    }

    function withdrawNeeded(uint amount) internal {

        uint tokenNeeded = amount.sub( collateral.balanceOf(address(this)) );
        uint price = yearnVault.getPricePerFullShare();

        // tokenNeeded / sharePrice = sharesNeeded
        uint adjusted = tokenNeeded.div(price);
        totalYearnDeposited = totalYearnDeposited.sub(adjusted);
        yearnVault.withdraw(adjusted);

    }

}