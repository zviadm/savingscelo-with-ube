//SPDX-License-Identifier: MIT
pragma solidity 0.6.8;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/ISavingsCELO.sol";
import "./interfaces/IUniswapV2.sol";

contract SavingsCELOWithUbeV1 {
	using SafeMath for uint256;

	ISavingsCELO public savingsCELO;
	IUniswapV2Router public ubeRouter;
	IUniswapV2Pair public ubePair;
	IERC20 public sCELO;
	IERC20 public CELO;

	event Deposited(address indexed from, uint256 celoAmount, uint256 savingsAmount, bool direct);
	event AddedLiquidity(address indexed from, uint256 celoAmount, uint256 savingsAmount, uint256 liquidity);

	constructor (
		address _savingsCELO,
		address _CELO,
		address _ubeRouter) public {
		savingsCELO = ISavingsCELO(_savingsCELO);
		sCELO = IERC20(_savingsCELO);
		CELO = IERC20(_CELO);

		ubeRouter = IUniswapV2Router(_ubeRouter);
		IUniswapV2Factory factory = IUniswapV2Factory(ubeRouter.factory());
		address _pair = factory.getPair(_savingsCELO, _CELO);
		if (_pair == address(0)) {
			_pair = factory.createPair(_savingsCELO, _CELO);
		}
		require(_pair != address(0), "Ubeswap pair must already exist!");
		ubePair = IUniswapV2Pair(_pair);
	}

	function deposit() external payable returns (uint256) {
		(uint256 reserve_CELO, uint256 reserve_sCELO) = ubeGetReserves();
		uint256 sCELOfromUbe = (reserve_CELO == 0 || reserve_sCELO == 0) ? 0 :
			ubeGetAmountOut(msg.value, reserve_CELO, reserve_sCELO);
		uint256 sCELOfromDirect = savingsCELO.celoToSavings(msg.value);

		uint256 sCELOReceived;
		bool direct;
		if (sCELOfromDirect >= sCELOfromUbe) {
			direct = true;
			sCELOReceived = savingsCELO.deposit{value: msg.value}();
			assert(sCELOReceived >= sCELOfromDirect);
		} else {
			direct = false;
			address[] memory path = new address[](2);
			path[0] = address(CELO);
			path[1] = address(sCELO);
			require(
				CELO.approve(address(ubeRouter), msg.value),
				"CELO approve failed for ubeRouter!");
			sCELOReceived = ubeRouter.swapExactTokensForTokens(
				msg.value, sCELOfromUbe, path, address(this), block.timestamp)[1];
			assert(sCELOReceived >= sCELOfromUbe);
		}
		require(
			sCELO.transfer(msg.sender, sCELOReceived),
			"sCELO transfer failed!");
		emit Deposited(msg.sender, msg.value, sCELOReceived, direct);
		return sCELOReceived;
	}

	function addLiquidity(
		uint256 amount_CELO,
		uint256 amount_sCELO,
		uint256 reserveMaxRatio
	) external returns (uint256 added_CELO, uint256 added_sCELO, uint256 addedLiquidity) {
		uint256 toConvert_CELO = calculateToConvertCELO(amount_CELO, amount_sCELO, reserveMaxRatio);
		uint256 converted_sCELO = 0;
		if (amount_CELO > 0) {
			require(
				CELO.transferFrom(msg.sender, address(this), amount_CELO),
				"CELO transferFrom failed!");
		}
		if (amount_sCELO > 0) {
			require(
				sCELO.transferFrom(msg.sender, address(this), amount_sCELO),
				"sCELO transferFrom failed!");
		}
		if (toConvert_CELO > 0) {
			converted_sCELO = savingsCELO.deposit{value: toConvert_CELO}();
			amount_sCELO = amount_sCELO.add(converted_sCELO);
			amount_CELO = amount_CELO.sub(toConvert_CELO);
		}
		if (amount_CELO > 0) {
			require(
				CELO.approve(address(ubeRouter), amount_CELO),
				"CELO approve failed for ubeRouter!");
		}
		if (amount_sCELO > 0) {
			require(
				sCELO.approve(address(ubeRouter), amount_sCELO),
				"sCELO approve failed for ubeRouter!");
		}
		(added_CELO, added_sCELO, addedLiquidity) = ubeRouter.addLiquidity(
			address(CELO), address(sCELO),
			amount_CELO, amount_sCELO,
			amount_CELO.sub(2), amount_sCELO,
			msg.sender, block.timestamp);

		added_CELO = added_CELO.add(toConvert_CELO);
		added_sCELO = added_sCELO.sub(converted_sCELO);
		emit AddedLiquidity(msg.sender, added_CELO, added_sCELO, addedLiquidity);
		return (added_CELO, added_sCELO, addedLiquidity);
	}

	function ubeGetReserves() public view returns (uint256 reserve_CELO, uint256 reserve_sCELO) {
		(uint256 reserve0, uint256 reserve1, ) = ubePair.getReserves();
		return (ubePair.token0() == address(CELO)) ? (reserve0, reserve1) : (reserve1, reserve0);
	}

	function ubeGetAmountOut(
		uint amountIn,
		uint reserveIn,
		uint reserveOut) internal pure returns (uint amountOut) {
		require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
		require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
		uint amountInWithFee = amountIn.mul(997);
		uint numerator = amountInWithFee.mul(reserveOut);
		uint denominator = reserveIn.mul(1000).add(amountInWithFee);
		amountOut = numerator / denominator;
	}

	function calculateToConvertCELO(
		uint256 amount_CELO,
		uint256 amount_sCELO,
		uint256 reserveMaxRatio
	) internal view returns (uint256 toConvert_CELO) {
		(uint256 reserve_CELO, uint256 reserve_sCELO) = ubeGetReserves();
		if (reserve_CELO == 0 && reserve_sCELO == 0) {
			reserve_CELO = 1;
			reserve_sCELO = savingsCELO.celoToSavings(1);
		}
		uint256 reserve_sCELOasCELO = savingsCELO.savingsToCELO(reserve_sCELO);
		require(
			reserve_CELO.mul(reserveMaxRatio) >= reserve_sCELOasCELO.mul(1e18),
			"Too little CELO in the liqudity pool. Adding liquidity is not safe!");
		require(
			reserve_sCELOasCELO.mul(reserveMaxRatio) >= reserve_CELO.mul(1e18),
			"Too little sCELO in the liqudity pool. Adding liquidity is not safe!");

		uint256 matched_CELO = amount_sCELO.mul(reserve_CELO).add(reserve_sCELO.sub(1)).div(reserve_sCELO);
		require(
			matched_CELO <= amount_CELO,
			"Too much sCELO. Can not add proportional liquidity!");
		return amount_CELO.sub(matched_CELO).mul(reserve_sCELOasCELO).div(reserve_CELO.add(reserve_sCELOasCELO));
	}
}
