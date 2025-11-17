// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IYunaSwapFactory {
    function getPair(address a, address b) external view returns (address);
    function createPair(address a, address b) external returns (address);
}

interface IYunaSwapRouter02 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint, uint, uint);
}

contract BondingCurveToken is ERC20, Ownable(msg.sender), ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable reserveToken;
    uint256 public virtualTokenReserve;
    uint256 public virtualReserveAsset;
    uint256 public immutable initialVirtualTokenReserve;
    uint256 public immutable initialRealTokenReservesStart;
    uint256 public immutable k;
    uint256 public remainingRealTokenReserves;
    uint256 public connectorBalance;
    uint256 public graduationReserveThreshold;
    bool public graduated;
    IYunaSwapRouter02 public immutable yunaswapRouter;
    IYunaSwapFactory public immutable yunaswapFactory;

    event Bought(address buyer, uint256 usdcIn, uint256 tokensMinted, uint256 virtualTokensTaken);
    event Sold(address seller, uint256 tokensBurned, uint256 usdcOut, uint256 virtualTokensReturned);
    event Graduated(address pair, uint256 tokensMintedToContract, uint256 reserveAdded);

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        address reserveTokenAddress_,
        uint256 initialVirtualTokenReserve_,
        uint256 initialVirtualReserveAsset_,
        uint256 realTokenReservesStart_,
        uint256 graduationReserveThreshold_,
        address yunaswapRouter_,
        address yunaswapFactory_
    ) ERC20(name_, symbol_) {
        reserveToken = IERC20(reserveTokenAddress_);
        virtualTokenReserve = initialVirtualTokenReserve_;
        virtualReserveAsset = initialVirtualReserveAsset_;
        initialVirtualTokenReserve = initialVirtualTokenReserve_;
        initialRealTokenReservesStart = realTokenReservesStart_;
        k = initialVirtualTokenReserve_ * initialVirtualReserveAsset_;
        remainingRealTokenReserves = realTokenReservesStart_;
        graduationReserveThreshold = graduationReserveThreshold_;
        yunaswapRouter = IYunaSwapRouter02(yunaswapRouter_);
        yunaswapFactory = IYunaSwapFactory(yunaswapFactory_);
        graduated = false;
        _transferOwnership(owner_);
    }

    function bondingCurveProgress() external view returns (uint256) {
        uint256 taken = initialVirtualTokenReserve - virtualTokenReserve;
        return (taken * 1e20) / initialRealTokenReservesStart;
    }

  function buy(uint256 amountIn) external nonReentrant returns (uint256) {
    require(!graduated, "graduated");
    require(amountIn > 0, "zero");

    reserveToken.safeTransferFrom(msg.sender, address(this), amountIn);

    uint256 deposit = amountIn;

    // If deposit is enough to reach graduation, cap it to what is needed
    if (!graduated && connectorBalance + deposit >= graduationReserveThreshold) {
        deposit = graduationReserveThreshold - connectorBalance;
    }

    connectorBalance += deposit;

    // Calculate virtual token movement
    uint256 newVirtualReserveAsset = virtualReserveAsset + deposit;
    uint256 newVirtualTokenReserve = k / newVirtualReserveAsset;

    uint256 virtualTokensTaken = virtualTokenReserve > newVirtualTokenReserve
        ? virtualTokenReserve - newVirtualTokenReserve
        : virtualTokenReserve; // fallback to remaining tokens to avoid 0

    uint256 tokensToMint = virtualTokensTaken;
    if (tokensToMint > remainingRealTokenReserves) {
        tokensToMint = remainingRealTokenReserves;
    }

    virtualReserveAsset = newVirtualReserveAsset;
    virtualTokenReserve = newVirtualTokenReserve;

    if (tokensToMint > 0) {
        remainingRealTokenReserves -= tokensToMint;
        _mint(msg.sender, tokensToMint);
    }

    emit Bought(msg.sender, deposit, tokensToMint, virtualTokensTaken);

    // Graduate if threshold reached
    if (!graduated && connectorBalance >= graduationReserveThreshold) {
        _graduate();
    }

    // Refund any excess beyond deposit needed to reach graduation
    if (amountIn > deposit) {
        uint256 extraRefund = amountIn - deposit;
        reserveToken.safeTransfer(msg.sender, extraRefund);
    }

    return tokensToMint;
}


    function sell(uint256 tokenAmount) external nonReentrant returns (uint256) {
        require(!graduated);
        require(tokenAmount > 0);

        bool ok = transferFromAllowedAndTransfer(msg.sender, address(this), tokenAmount);
        require(ok);

        _burn(address(this), tokenAmount);

        uint256 newVirtualTokenReserve = virtualTokenReserve + tokenAmount;
        uint256 newVirtualReserveAsset = k / newVirtualTokenReserve;

        uint256 reserveOut = virtualReserveAsset - newVirtualReserveAsset;

        virtualTokenReserve = newVirtualTokenReserve;
        virtualReserveAsset = newVirtualReserveAsset;

        require(connectorBalance >= reserveOut);
        connectorBalance -= reserveOut;
        remainingRealTokenReserves += tokenAmount;
        reserveToken.safeTransfer(msg.sender, reserveOut);

        emit Sold(msg.sender, tokenAmount, reserveOut, tokenAmount);

        return reserveOut;
    }

    function transferFromAllowedAndTransfer(address from, address to, uint256 amount) internal returns (bool) {
        bool success = false;
        try ERC20(address(this)).transferFrom(from, to, amount) returns (bool _ok) {
            success = _ok;
        } catch {}
        return success;
    }

    function _graduate() internal {
        require(!graduated);

        address pair = yunaswapFactory.getPair(address(this), address(reserveToken));
        if (pair == address(0)) {
            pair = yunaswapFactory.createPair(address(this), address(reserveToken));
        }

        uint256 reserveToAdd = connectorBalance;
        require(reserveToAdd > 0);

        uint256 tokensNeeded = (reserveToAdd * virtualTokenReserve) / virtualReserveAsset;
        if (tokensNeeded > remainingRealTokenReserves) {
            tokensNeeded = remainingRealTokenReserves;
        }
        require(tokensNeeded > 0);

        remainingRealTokenReserves -= tokensNeeded;
        _mint(address(this), tokensNeeded);

        _approve(address(this), address(yunaswapRouter), tokensNeeded);
        reserveToken.approve(address(yunaswapRouter), reserveToAdd);

        (uint256 amountTokenAdded, uint256 amountReserveAdded,) =
            yunaswapRouter.addLiquidity(
                address(this),
                address(reserveToken),
                tokensNeeded,
                reserveToAdd,
                0,
                0,
                owner(),
                block.timestamp + 1800
            );

        if (amountReserveAdded <= connectorBalance) {
            connectorBalance -= amountReserveAdded;
        } else {
            connectorBalance = 0;
        }

        graduated = true;

        emit Graduated(pair, amountTokenAdded, amountReserveAdded);
    }

    function withdrawLeftoverReserve(address to, uint256 amount) external onlyOwner {
        require(graduated);
        require(amount <= connectorBalance);
        connectorBalance -= amount;
        reserveToken.safeTransfer(to, amount);
    }

    function withdrawReserve(address to) external onlyOwner {
        uint256 bal = reserveToken.balanceOf(address(this));
        reserveToken.safeTransfer(to, bal);
        connectorBalance = reserveToken.balanceOf(address(this));
    }

    receive() external payable {}
}

contract BondingCurveFactory is Ownable(msg.sender) {
    event TokenCreated(address token);

    function createToken(
        string memory name_,
        string memory symbol_,
        address reserveToken_,
        uint256 initialVirtualTokenReserve_,
        uint256 initialVirtualReserveAsset_,
        uint256 realTokenReservesStart_,
        uint256 graduationReserveThreshold_,
        address yunaswapRouter_,
        address yunaswapFactory_
    ) external onlyOwner returns (address) {
        BondingCurveToken t = new BondingCurveToken(
            name_,
            symbol_,
            msg.sender,
            reserveToken_,
            initialVirtualTokenReserve_,
            initialVirtualReserveAsset_,
            realTokenReservesStart_,
            graduationReserveThreshold_,
            yunaswapRouter_,
            yunaswapFactory_
        );
        emit TokenCreated(address(t));
        return address(t);
    }
}
