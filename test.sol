// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Pair.sol";
import "./IUniswapV2Router02.sol";


contract WKM is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;

    mapping (address => uint256) private _rOwned; // 默认余额
    mapping (address => uint256) private _tOwned; // 排除余额[实际余额]
    mapping (address => mapping (address => uint256)) private _allowances; // 授权

    mapping (address => bool) private _isExcludedFromFee;

    mapping (address => bool) private _isExcluded; // 排除列表
    address[] private _excluded; // 排除列表

    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 1000000000 * 10**6 * 10**9; // 排除流通量[实际流通量]
    uint256 private _rTotal = (MAX - (MAX % _tTotal)); // 默认余额
    uint256 private _tFeeTotal; // 累计手续费

    string private _name = "WKMoon";
    string private _symbol = "WKM";
    uint8 private _decimals = 9;

    uint256 public _taxFee = 5;
    uint256 private _previousTaxFee = _taxFee;

    uint256 public _liquidityFee = 5;
    uint256 private _previousLiquidityFee = _liquidityFee;

    IUniswapV2Router02 public immutable uniswapV2Router;
    address public immutable uniswapV2Pair;

    bool inSwapAndLiquify;
    bool public swapAndLiquifyEnabled = true;

    uint256 public _maxTxAmount = 5000000 * 10**6 * 10**9; // 最大持有手续费
    uint256 private numTokensSellToAddToLiquidity = 500000 * 10**6 * 10**9; // 大于该值可进行添加Uni流动性

    event MinTokensBeforeSwapUpdated(uint256 minTokensBeforeSwap);
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );
    // 添加流动性操作锁，防止重入
    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    constructor (address router) public {
        _rOwned[_msgSender()] = _rTotal;  // 把币mint给创建者

        // #如果router地址不是swapRouter地址合约部署不成功
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(router);
        // 创建在Uniswap上的 该Token兑换ETH的交易对
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
        .createPair(address(this), _uniswapV2Router.WETH());

        // set the rest of the contract variables
        uniswapV2Router = _uniswapV2Router;

        // 合约创建者和该合约交易不需要手续费
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;

        emit Transfer(address(0), _msgSender(), _tTotal);
    }
    // 名称
    function name() public view returns (string memory) {
        return _name;
    }
    // 缩写
    function symbol() public view returns (string memory) {
        return _symbol;
    }
    // 精度
    function decimals() public view returns (uint8) {
        return _decimals;
    }
    // 流通量
    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }
    // 余额
    function balanceOf(address account) public view override returns (uint256) {
        // 用户是否被排除
        if (_isExcluded[account]) return _tOwned[account]; // 为排除余额
        return tokenFromReflection(_rOwned[account]); // 用默认余额计算实际余额
    }
    // 转账
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }
    // 查询授权
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    // 授权
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }
    // 授权转账
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }
    // 增加授权
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }
    // 减少授权
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }
    // 是否被排除
    function isExcludedFromReward(address account) public view returns (bool) {
        return _isExcluded[account];
    }
    // 累计手续费
    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }
    // 用户把余额变成手续费
    function deliver(uint256 tAmount) public {
        address sender = _msgSender(); // 操作人
        // 排除地址不能进行操作
        require(!_isExcluded[sender], "Excluded addresses cannot call this function");
        // 计算对应的默认数量
        (uint256 rAmount,,,,,) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount); // 扣除余额
        _rTotal = _rTotal.sub(rAmount); // 减少流通量
        _tFeeTotal = _tFeeTotal.add(tAmount); // 添加手续费总量
    }
    // 计算排除数量对应的默认数量 或者到账的默认数量
    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }
    // 计算实际余额
    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate =  _getRate();
        return rAmount.div(currentRate);
    }
    // 把一个账户进行排除操作
    function excludeFromReward(address account) public onlyOwner() {
        // require(account != 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, 'We can not exclude Uniswap router.');
        require(!_isExcluded[account], "Account is already excluded");
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }
    // 取消一个排除账户的排除状态
    function includeInReward(address account) external onlyOwner() {
        require(_isExcluded[account], "Account is already excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0; // 排除余额变成0
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }
    // 不收用户手续费
    function excludeFromFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }
    // 收用户手续费
    function includeInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }
    // 查询是否收用户手续费 true不收
    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }
    // 设置转账手续费
    function setTaxFeePercent(uint256 taxFee) external onlyOwner() {
        _taxFee = taxFee;
    }
    // 设置流动性手续费
    function setLiquidityFeePercent(uint256 liquidityFee) external onlyOwner() {
        _liquidityFee = liquidityFee;
    }
    // 设置最大接收手续费的手续百分比
    function setMaxTxPercent(uint256 maxTxPercent) external onlyOwner() {
        _maxTxAmount = _tTotal.mul(maxTxPercent).div(
            10**2
        );
    }
    // 是否添加Uni流动性
    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    // 接受ETH
    receive() external payable {}
    // 把默认余额转换到排除余额
    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }
    // 计算排除数量的 默认数量 默认到账数量 默认转账手续费 排除到账数量 排除转账手续费 排除流动性费用
    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        // 交易手续费 流动性手续费 到账数量
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, tLiquidity, _getRate());
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tLiquidity);
    }
    // 用排除数量计算交易的 交易手续费 流动性手续费 到账数量
    function _getTValues(uint256 tAmount) private view returns (uint256, uint256, uint256) {
        uint256 tFee = calculateTaxFee(tAmount); // 计算交易手续费
        uint256 tLiquidity = calculateLiquidityFee(tAmount); // 计算流动性手续费
        uint256 tTransferAmount = tAmount.sub(tFee).sub(tLiquidity); // 到账数量
        return (tTransferAmount, tFee, tLiquidity);
    }
    // 把排除的[数量、到账手续费、交易手续费]计算出对应的默认数量
    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tLiquidity, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate); // 用排除数量计算默认数量
        uint256 rFee = tFee.mul(currentRate); // 排除手续费计算默认手续费
        uint256 rLiquidity = tLiquidity.mul(currentRate); // 流动性手续费计算排除流动性手续费
        uint256 rTransferAmount = rAmount.sub(rFee).sub(rLiquidity); // 到账数量
        return (rAmount, rTransferAmount, rFee);
    }
    // 获取默认流通量和排除流通量的比例
    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }
    // 计算有效的默认流通量和排除流通量
    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal; // 默认流通量
        uint256 tSupply = _tTotal; // 排除流通量
        for (uint256 i = 0; i < _excluded.length; i++) { // 循环排除列表
            // 用户余额大于流通量
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]); // 去除排除用户的默认流通量
            tSupply = tSupply.sub(_tOwned[_excluded[i]]); // 去除排除用户的排除流通量
        }
        // 默认流通量 小于 实际流通量
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
    // 添加流动性 用于在Uni上添加流动性
    function _takeLiquidity(uint256 tLiquidity) private {
        uint256 currentRate =  _getRate();
        uint256 rLiquidity = tLiquidity.mul(currentRate); // 计算对应的默认数量
        _rOwned[address(this)] = _rOwned[address(this)].add(rLiquidity); // 把这部分数量给合约
        if(_isExcluded[address(this)]) // 如果合约被排除
            _tOwned[address(this)] = _tOwned[address(this)].add(tLiquidity); // 添加排除余额
    }
    // 计算转账需要的手续费
    function calculateTaxFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_taxFee).div(
            10**2
        );
    }
    // 计算流动性手续费
    function calculateLiquidityFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_liquidityFee).div(
            10**2
        );
    }
    // 设置手续费率为0并备份
    function removeAllFee() private {
        if(_taxFee == 0 && _liquidityFee == 0) return;

        _previousTaxFee = _taxFee;
        _previousLiquidityFee = _liquidityFee;

        _taxFee = 0;
        _liquidityFee = 0;
    }
    // 恢复手续费率
    function restoreAllFee() private {
        _taxFee = _previousTaxFee;
        _liquidityFee = _previousLiquidityFee;
    }

    // 授权
    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
    // 转账
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        if(from != owner() && to != owner()) // 如果转账有合约创建者参与
            require(amount <= _maxTxAmount, "Transfer amount exceeds the maxTxAmount."); // 转账数量大于总量 回滚

        // is the token balance of this contract address over the min number of
        // tokens that we need to initiate a swap + liquidity lock?
        // also, don't get caught in a circular liquidity event.
        // also, don't swap & liquify if sender is uniswap pair.
        uint256 contractTokenBalance = balanceOf(address(this)); // 合约token余额[收到的手续费]

        if(contractTokenBalance >= _maxTxAmount) { // 手续费数量大于最大手续费数量
            contractTokenBalance = _maxTxAmount; // 该值等于最大值
        }

        bool overMinTokenBalance = contractTokenBalance >= numTokensSellToAddToLiquidity;
        if (
            overMinTokenBalance && // 手续费超量
            !inSwapAndLiquify && // 当前合约没有进行流通性添加操作
            from != uniswapV2Pair && // 发起转账用户不是Uni的交易对
            swapAndLiquifyEnabled // 开启了添加流动性
        ) {
            contractTokenBalance = numTokensSellToAddToLiquidity;
            // 添加流动性
            swapAndLiquify(contractTokenBalance);
        }

        //indicates if fee should be deducted from transfer
        bool takeFee = true; // 收取手续费

        // if any account belongs to _isExcludedFromFee account then remove the fee
        // 如果任何帐户属于费用帐户，则删除费用
        if(_isExcludedFromFee[from] || _isExcludedFromFee[to]){
            takeFee = false;
        }

        //transfer amount, it will take tax, burn, liquidity fee
        _tokenTransfer(from,to,amount,takeFee);
    }
    // 把传入的数量用来添加流动性
    function swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {
        // 把合约余额分成两半
        uint256 half = contractTokenBalance.div(2);
        uint256 otherHalf = contractTokenBalance.sub(half);

        // 获取合同的当前ETH余额。
        // 这样，我们就可以准确地获取掉期产生的ETH金额，而不会使流动性事件包括任何手动发送到合同的ETH
        uint256 initialBalance = address(this).balance;

        // 把传入数量的一半用来卖出ETH
        swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // 获取换到的ETH数量
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // 把剩余一半的token和换到的ETH来添加流动性
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }
    // 卖出token
    function swapTokensForEth(uint256 tokenAmount) private {
        // 构造交易路径
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();
        // 授权Uni使用token
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // 交换
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }
    // 在Uni上添加token-ETH的流动性
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );
    }

    //this method is responsible for taking all fee, if takeFee is true
    // 转账 发送者 接收者 数量 是否接收手续费
    function _tokenTransfer(address sender, address recipient, uint256 amount,bool takeFee) private {
        if(!takeFee) // 如果不收手续费
            removeAllFee(); // 设置手续费率为0

        if (_isExcluded[sender] && !_isExcluded[recipient]) { // 发送者是排除账户 接受者不是
            _transferFromExcluded(sender, recipient, amount); // 发起者是排除这的转账
        }
        else if (!_isExcluded[sender] && _isExcluded[recipient]) { // 接收者是排除账户 发送者不是
            _transferToExcluded(sender, recipient, amount);   //
        }
        else if (!_isExcluded[sender] && !_isExcluded[recipient]) { // 两者都不是排除账户
            _transferStandard(sender, recipient, amount);
        }
        else if (_isExcluded[sender] && _isExcluded[recipient]) { // 两者都是排除账户
            _transferBothExcluded(sender, recipient, amount);
        }
        else {
            _transferStandard(sender, recipient, amount);
        }

        if(!takeFee) // 如果不接收手续费
            restoreAllFee(); // 恢复手续费率
    }
    /**
     * 下边几个方法的区别主要是 排除账户需要更新两个余额，普通账户更新默认余额即可
     */
    // 排除账户之间转账
    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount); // 扣除排除余额
        _rOwned[sender] = _rOwned[sender].sub(rAmount); // 扣除默认余额
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount); // 添加排除余额
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount); // 添加默认余额
        _takeLiquidity(tLiquidity); // 添加流动性
        _reflectFee(rFee, tFee); // 添加手续费
        emit Transfer(sender, recipient, tTransferAmount);
    }
    // 普通用户之间转账
    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }
    // 普通用户转给排除账户
    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        emit Transfer(sender, recipient, tTransferAmount);
    }
    // 发起者是排除这的转账
    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount); // 扣款
        _rOwned[sender] = _rOwned[sender].sub(rAmount); // 扣款
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount); // 添加余额
        _takeLiquidity(tLiquidity); // 添加流动性
        _reflectFee(rFee, tFee); // 添加手续费
        emit Transfer(sender, recipient, tTransferAmount);
    }
}