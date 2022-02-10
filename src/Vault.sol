// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12;

import "./libraries/safemath.sol";
import "./libraries/IERC20.sol";
import "./libraries/yearnVault.sol";

// Special thanks to twiiter@prism0x for this distribution algo
// https://solmaz.io/2019/02/24/scalable-reward-changing/

// minimial approch to self repaying loans, hardcodes 75% LTV or about 133% over-collaterizaiton
// eventually will make this adjustable

contract pVault {

    using SafeMath for uint;

    // #########################
    // ##                     ##
    // ##       Structs       ##
    // ##                     ##
    // #########################

    struct Identity {
        uint256 deposits;
        uint256 debt;
        uint256 tracker; // sum of changes of deposit * yeildPerToken
    }

    struct Context {
        // Basis Points
        uint16 maxLTV;
        uint16 fee;
    }

    // #########################
    // ##                     ##
    // ##       State         ##
    // ##                     ##
    // #########################

    // ENSURE COLLATERAL AND SYNTH TOKEN REVERTS ON FAILED TRANSFER
    IERC20 internal collateral;
    IERC20 internal synthetic;
    yVault internal yearnVault;
    address immutable feeCollector;

    mapping (address => Identity) identity;

    //totalDebt = supply of synth
    uint256 public totalDeposits;
    uint256 public totalYearnDeposited;
    uint256 public feesAccumlated;

    // 75% = ~133% Over-collaterized
    // 75% BP LTV :: 1.25% BP fee
    Context ctx = Context(7500, 125);

    // sum of all distribution events ( yeild / totalDeposits )
    // scaled 1e10.. As long as rewards accumlated between distributions
    // are greater than 1/1e10 totalDeposits , distribute() should return a nonzero value
    uint256 internal yeildPerDeposit;
    uint256 internal SCALAR;

    constructor(
        address _synthetic, 
        address _yearnVault, 
        address _collateral, 
        address _feeCollector
    ) {
    
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

        identity[msg.sender].deposits = identity[msg.sender].deposits.add(amount);
        totalDeposits = totalDeposits.add(amount);

        identity[msg.sender].tracker = 
            identity[msg.sender].tracker
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

        identity[msg.sender].deposits = identity[msg.sender].deposits.sub(amount);
        totalDeposits = totalDeposits.sub(amount);

        identity[msg.sender].tracker = 
            identity[msg.sender].tracker
                .sub(yeildPerDeposit.mul(amount).div(SCALAR));
        
        if ( amount > collateral.balanceOf(address(this)) ) {

            withdrawNeeded(amount);

        }

        collateral.transfer(msg.sender, amount);

    }

    function incurDebt(uint amount) external {

        require( 
            identity[msg.sender].debt.add(amount) <= identity[msg.sender].deposits.mul(ctx.maxLTV).div(10000) 
        );

        identity[msg.sender].debt = identity[msg.sender].debt.add(amount);

        uint feeAdjust = amount.mul(ctx.fee).div(10000);
        feesAccumlated = feesAccumlated.add( amount.sub(feeAdjust) );

        synthetic.mint(msg.sender, feeAdjust);

    }

    function repayDebtSynth(uint amount) external {

        require ( identity[msg.sender].debt >= amount );
        identity[msg.sender].debt = identity[msg.sender].debt.sub(amount);

        synthetic.transferFrom(msg.sender, address(this), amount); //change to burn

    }

    function repayDebtAsset(uint amount) external {

        require ( identity[msg.sender].debt >= amount );
        identity[msg.sender].debt = identity[msg.sender].debt.sub(amount);

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

    function burnSynth(uint amount) public {

        // reverts on fail
        synthetic.transferFrom(msg.sender, address(0), amount);

        // system should always be overcollatirzed so this cant fail
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

        uint deposits = identity[who].deposits;
        uint yeild = deposits
            .mul(yeildPerDeposit).div(SCALAR)
                .sub(identity[msg.sender].tracker);

        // 75% of deposit = ~133% over-collateralized
        uint overCollatDebt = identity[who].debt.mul(13300).div(10000);

        return deposits.sub(overCollatDebt).add(yeild);

    }

    function withdrawNeeded(uint amount) internal {

        uint tokenNeeded = amount.sub( collateral.balanceOf(address(this)) );
        uint price = yearnVault.getPricePerFullShare();

        // tokenNeeded / sharePrice = sharesNeeded
        uint sharesNeeded = tokenNeeded.div(price);
        totalYearnDeposited = totalYearnDeposited.sub(sharesNeeded);
        yearnVault.withdraw(sharesNeeded);

    }

}