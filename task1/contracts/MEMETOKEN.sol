// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MEMETK is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000 * 1e18;
    uint256 public constant MAX_TX_PERCENT = 1; // 每笔交易最多 1%

    address public marketingWallet;
    uint256 public taxFee = 4; // 总税 4%
    uint256 public liquidityFee = 2; // 自动加池 2%
    uint256 public marketingFee = 2; // 营销地址 2%

    IUniswapV2Router02 public uniswapRouter;
    address public uniswapPair;

    bool public swapEnabled = true;
    bool private inSwap;

    uint256 public swapThreshold = 1000 * 1e18;
    mapping(address => bool) public isExcludedFromFee;

    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(address _router, address _marketingWallet) ERC20("MEMETK", "MMTK") Ownable(msg.sender) {
        _mint(msg.sender, TOTAL_SUPPLY);
        marketingWallet = _marketingWallet;

        IUniswapV2Router02 _uniswapRouter = IUniswapV2Router02(_router);
        address _pair = IUniswapV2Factory(_uniswapRouter.factory()).createPair(address(this), _uniswapRouter.WETH());

        uniswapRouter = _uniswapRouter;
        uniswapPair = _pair;

        isExcludedFromFee[msg.sender] = true;
        isExcludedFromFee[address(this)] = true;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0) && to != address(0), "Invalid address");

        // 限制最大交易额
        if (!isExcludedFromFee[from] && !isExcludedFromFee[to]) {
            uint256 maxTx = (totalSupply() * MAX_TX_PERCENT) / 100;
            require(amount <= maxTx, "Exceeds max transaction amount");
        }

        uint256 contractTokenBalance = balanceOf(address(this));
        if (contractTokenBalance >= swapThreshold && !inSwap && from != uniswapPair && swapEnabled) {
            swapAndLiquify(contractTokenBalance);
        }

        // 扣税
        if (!isExcludedFromFee[from] && !isExcludedFromFee[to]) {
            uint256 feeAmount = (amount * taxFee) / 100;
            super._transfer(from, address(this), feeAmount);
            amount -= feeAmount;
        }

        super._transfer(from, to, amount);
    }

    function swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {
        uint256 halfLiquidity = (contractTokenBalance * liquidityFee) / taxFee / 2;
        uint256 otherHalf = (contractTokenBalance * liquidityFee) / taxFee - halfLiquidity;
        uint256 marketingPart = (contractTokenBalance * marketingFee) / taxFee;

        uint256 swapAmount = halfLiquidity + marketingPart;
        uint256 initialBalance = address(this).balance;

        // 换 ETH
        swapTokensForEth(swapAmount);
        uint256 newBalance = address(this).balance - initialBalance;

        uint256 ethForLiquidity = (newBalance * halfLiquidity) / swapAmount;
        addLiquidity(otherHalf, ethForLiquidity);

        payable(marketingWallet).transfer(address(this).balance);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();

        _approve(address(this), address(uniswapRouter), tokenAmount);

        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        _approve(address(this), address(uniswapRouter), tokenAmount);

        uniswapRouter.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            owner(),
            block.timestamp
        );
    }

    receive() external payable {}

    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
    }

    function setExcludedFromFee(address account, bool excluded) external onlyOwner {
        isExcludedFromFee[account] = excluded;
    }
} 
