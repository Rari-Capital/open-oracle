const { uint, keccak256, time, numToHex, address, sendRPC, currentBlockTimestamp, fixed } = require('./Helpers');
const BigNumber = require('bignumber.js');

const PriceSource = {
  FIXED_ETH: 0,
  FIXED_USD: 1,
  REPORTER: 2,
  TWAP: 3
};
const FIXED_ETH_AMOUNT = 0.005e18;

async function setup({isMockedView, freeze}) {
  const anchorPeriod = 60;
  const timestamp = 1600000000;


  if (freeze) {
    await sendRPC(web3, 'evm_freezeTime', [timestamp]);
  } else {
    await sendRPC(web3, 'evm_mine', [timestamp]);
  }

  const mockPair = await deploy("MockUniswapTokenPair", [
    fixed(1.8e12),
    fixed(8.2e21),
    fixed(1.6e9),
    fixed(1.19e50),
    fixed(5.8e30),
  ]);

    // Initialize REP pair with values from mainnet
  const mockRepPair = await deploy("MockUniswapTokenPair", [
    fixed(4e22),
    fixed(3e21),
    fixed(1.6e9),
    fixed(1.32e39),
    fixed(3.15e41),
  ]);

  const underlying = {ETH: address(0), DAI: address(1), REP: address(2), USDT: address(3), SAI: address(4), WBTC: address(5), USDC: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"};
  
  var cToken = {};
  for (const symbol of Object.keys(underlying)) cToken[symbol] = (await deploy('MockCToken', [underlying[symbol]]))._address;

  const tokenConfigs = [
    {underlying: underlying.DAI, symbolHash: keccak256('DAI'), baseUnit: uint(1e18), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: mockPair._address, isUniswapReversed: false},
    {underlying: underlying.REP, symbolHash: keccak256('REP'), baseUnit: uint(1e18), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: mockRepPair._address, isUniswapReversed: false},
    {underlying: underlying.USDT, symbolHash: keccak256('USDT'), baseUnit: uint(1e6), priceSource: PriceSource.FIXED_USD, fixedPrice: uint(1e6), uniswapMarket: address(0), isUniswapReversed: false},
    {underlying: underlying.SAI, symbolHash: keccak256('SAI'), baseUnit: uint(1e18), priceSource: PriceSource.FIXED_ETH, fixedPrice: uint(FIXED_ETH_AMOUNT), uniswapMarket: address(0), isUniswapReversed: false},
    {underlying: underlying.WBTC, symbolHash: keccak256('BTC'), baseUnit: uint(1e8), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: mockPair._address, isUniswapReversed: false},
    {underlying: underlying.USDC, symbolHash: keccak256('USDC'), baseUnit: uint(1e6), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: mockPair._address, isUniswapReversed: false},
  ];

  let uniswapView;
  if (isMockedView) {
    uniswapView = await deploy('MockUniswapView', [anchorPeriod, tokenConfigs]);
  } else {
    uniswapView = await deploy('UniswapView', [anchorPeriod, tokenConfigs, false, false]);
  }

  async function postPrices(symbols) {
    return send(uniswapView, 'postPrices', [symbols]);
  }

  return {
    anchorPeriod,
    cToken,
    underlying,
    mockPair,
    postPrices,
    timestamp,
    tokenConfigs,
    uniswapView,
  };
}

describe('UniswapView', () => {
  let cToken;
  let underlying;
  let anchorPeriod;
  let uniswapView;
  let tokenConfigs;
  let postPrices;
  let mockPair;
  let timestamp;

  describe('postPrices', () => {
    beforeEach(async () => {
      ({
        underlying,
        postPrices,
        uniswapView,
      } = await setup({isMockedView: true}));
    });

    it('should update view', async () => {
      await send(uniswapView, 'setAnchorPrice', [underlying.REP, 17e6]);
      const tx = await postPrices([underlying.REP]);

      expect(tx.events.PriceUpdated.returnValues.price).numEquals(17e6);
      expect(tx.events.PriceUpdated.returnValues.underlying).toBe(underlying.REP);
      expect(await call(uniswapView, 'prices', [underlying.REP])).numEquals(17e6);
    });

    it('should revert on posting arrays with invalid underlyings', async () => {
      await expect(
        postPrices([address(123)])
      ).rejects.toRevert("revert token config not found");
    });

    it("should revert on posting FIXED_USD prices", async () => {
      await expect(
        postPrices([underlying.USDT])
      ).rejects.toRevert("revert only TWAP prices get posted");
    });

    it("should revert on posting FIXED_ETH prices", async () => {
      await expect(
        postPrices([underlying.SAI])
      ).rejects.toRevert("revert only TWAP prices get posted");
    });
});

  describe('getUnderlyingPrice', () => {
    // everything must return 1e36 - underlying units

    beforeEach(async () => {
      ({
        cToken,
        underlying,
        postPrices,
        uniswapView,
      } = await setup({isMockedView: true}));
    });

    it('should work correctly for USDT fixed USD price source', async () => {
      await send(uniswapView, 'setAnchorPrice', [underlying.USDC, FIXED_ETH_AMOUNT]);
      const tx = await postPrices([underlying.USDC]);
      // priceInternal:      returns 1e6 * 0.005e18 / 1e6 = 0.005e18
      // getUnderlyingPrice:         1e18 * 0.005e18 / 1e6 = 0.005e30
      let expected = new BigNumber('0.005e30');
      expect(await call(uniswapView, 'getUnderlyingPrice', [cToken.USDT])).numEquals(expected.toFixed());
    });

    it('should return fixed ETH amount if SAI', async () => {
      expect(await call(uniswapView, 'getUnderlyingPrice', [cToken.SAI])).numEquals(FIXED_ETH_AMOUNT);
    });

    it('should return 1e18 for ETH price', async () => {
      expect(await call(uniswapView, 'getUnderlyingPrice', [cToken.ETH])).numEquals(1e18);
    });

    it('should return reported USDC price', async () => {
      await send(uniswapView, 'setAnchorPrice', [underlying.USDC, FIXED_ETH_AMOUNT]);
      const tx = await postPrices([underlying.USDC]);
      // priceInternal:      returns 0.005e18
      // getUnderlyingPrice: 1e18 * 0.005e18 / 1e6 = 0.005e30
      let expected = new BigNumber('0.005e30');
      expect(await call(uniswapView, 'getUnderlyingPrice', [cToken.USDC])).numEquals(expected.toFixed());
    });

    it('should return reported WBTC price', async () => {
      let anchorPrice = new BigNumber('50e18');
      await send(uniswapView, 'setAnchorPrice', [underlying.WBTC, anchorPrice.toFixed()]);
      const tx = await postPrices([underlying.WBTC]);
      const btcPrice  = await call(uniswapView, 'prices', [underlying.WBTC]);
      expect(btcPrice).numEquals(anchorPrice.toFixed());
      // priceInternal:      returns 50e18
      // getUnderlyingPrice: 1e18 * 50e18 / 1e8 = 50e28
      let expected = new BigNumber('50e28');
      expect(await call(uniswapView, 'getUnderlyingPrice', [cToken.WBTC])).numEquals(expected.toFixed());
    });

  });

  describe('pokeWindowValues', () => {
    beforeEach(async () => {
      ({
        underlying,
        mockPair,
        anchorPeriod,
        uniswapView,
        postPrices,
        tokenConfigs,
        timestamp
      } = await setup({isMockedView: false, freeze: true}));
    });

    it('should not update window values if not enough time elapsed', async () => {
      await sendRPC(web3, 'evm_freezeTime', [timestamp + anchorPeriod - 5]);
      const tx = await postPrices([underlying.USDC]);
      expect(tx.events.UniswapWindowUpdated).toBe(undefined);
    });

    it('should update window values if enough time elapsed', async () => {
      const mkt = mockPair._address;
      const newObs1 = await call(uniswapView, 'newObservations', [underlying.USDC]);
      const oldObs1 = await call(uniswapView, 'oldObservations', [underlying.USDC]);

      let timestampLater = timestamp + anchorPeriod;
      await sendRPC(web3, 'evm_freezeTime', [timestampLater]);

      const tx1 = await postPrices([underlying.USDC]);
      const updateEvent = tx1.events.AnchorPriceUpdated.returnValues;
      expect(updateEvent.newTimestamp).greaterThan(updateEvent.oldTimestamp);

      // on the first update, we expect the new observation to change
      const newObs2 = await call(uniswapView, 'newObservations', [underlying.USDC]);
      const oldObs2 = await call(uniswapView, 'oldObservations', [underlying.USDC]);
      expect(newObs2.acc).greaterThan(newObs1.acc);
      expect(newObs2.timestamp).greaterThan(newObs1.timestamp);
      expect(oldObs2.acc).numEquals(oldObs1.acc);
      expect(oldObs2.timestamp).numEquals(oldObs1.timestamp);

      let timestampEvenLater = timestampLater + anchorPeriod;
      await sendRPC(web3, 'evm_freezeTime', [timestampEvenLater]);
      const tx2 = await postPrices([underlying.USDC]);

      const windowUpdate = tx2.events.UniswapWindowUpdated.returnValues;
      expect(windowUpdate.underlying).toEqual(underlying.USDC);
      expect(timestampEvenLater).greaterThan(windowUpdate.oldTimestamp);
      expect(windowUpdate.newPrice).greaterThan(windowUpdate.oldPrice);// accumulator should always go up

      // this time, both should change
      const newObs3 = await call(uniswapView, 'newObservations', [underlying.USDC]);
      const oldObs3 = await call(uniswapView, 'oldObservations', [underlying.USDC]);
      expect(newObs3.acc).greaterThan(newObs2.acc);
      expect(newObs3.acc).greaterThan(newObs2.timestamp);
      // old becomes last new
      expect(oldObs3.acc).numEquals(newObs2.acc);
      expect(oldObs3.timestamp).numEquals(newObs2.timestamp);

      const anchorPriceUpdated = tx2.events.AnchorPriceUpdated.returnValues;
      expect(anchorPriceUpdated.underlying).toBe(underlying.USDC);
      expect(anchorPriceUpdated.newTimestamp).greaterThan(anchorPriceUpdated.oldTimestamp);
      expect(oldObs3.timestamp).toBe(anchorPriceUpdated.oldTimestamp);
    });
  })

  describe('constructor', () => {
    it('should fail if baseUnit == 0', async () => {
      const mockPair = await deploy("MockUniswapTokenPair", [
        fixed(1.8e12),
        fixed(8.2e21),
        fixed(1.6e9),
        fixed(1.19e50),
        fixed(5.8e30),
      ]);
      const tokenConfigs = [
        // Set dummy address as a uniswap market address
        {underlying: address(1), symbolHash: keccak256('ETH'), baseUnit: uint(1e18), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: mockPair._address, isUniswapReversed: true},
        {underlying: address(2), symbolHash: keccak256('DAI'), baseUnit: 0, priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: mockPair._address, isUniswapReversed: false},
        {underlying: address(3), symbolHash: keccak256('REP'), baseUnit: uint(1e18), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: mockPair._address, isUniswapReversed: false}];
      await expect(
        deploy('UniswapView', [30, tokenConfigs, false, false])
      ).rejects.toRevert("revert baseUnit must be greater than zero");
    });

    it('should fail if uniswap market is not defined', async () => {
      const dummyAddress = address(0);
      const tokenConfigs = [
        // Set dummy address as a uniswap market address
        {underlying: address(1), symbolHash: keccak256('ETH'), baseUnit: uint(1e18), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: dummyAddress, isUniswapReversed: true},
        {underlying: address(2), symbolHash: keccak256('DAI'), baseUnit: uint(1e18), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: address(4), isUniswapReversed: false},
        {underlying: address(3), symbolHash: keccak256('REP'), baseUnit: uint(1e18), priceSource: PriceSource.TWAP, fixedPrice: 0, uniswapMarket: address(5), isUniswapReversed: false}];
      await expect(
        deploy('UniswapView', [30, tokenConfigs, false, false])
      ).rejects.toRevert("revert TWAP prices must have a Uniswap market");
    });

    it('should fail if non-TWAP price utilizes a Uniswap market', async () => {
      const tokenConfigs1 = [
        {underlying: address(2), symbolHash: keccak256('USDT'), baseUnit: uint(1e18), priceSource: PriceSource.FIXED_USD, fixedPrice: 0, uniswapMarket: address(5), isUniswapReversed: false}];
      await expect(
        deploy('UniswapView', [30, tokenConfigs1, false, false])
      ).rejects.toRevert("revert only TWAP prices utilize a Uniswap market");

      const tokenConfigs2 = [
        {underlying: address(2), symbolHash: keccak256('USDT'), baseUnit: uint(1e18), priceSource: PriceSource.FIXED_ETH, fixedPrice: 0, uniswapMarket: address(5), isUniswapReversed: false}];
      await expect(
        deploy('UniswapView', [30, tokenConfigs2, false, false])
      ).rejects.toRevert("revert only TWAP prices utilize a Uniswap market");
    });

    it('basic scenario, successfully initialize observations initial state', async () => {
      ({anchorPeriod, uniswapView, tokenConfigs} = await setup({isMockedView: true}));
      expect(await call(uniswapView, 'anchorPeriod')).numEquals(anchorPeriod);

      await Promise.all(tokenConfigs.map(async config => {
        const oldObservation = await call(uniswapView, 'oldObservations', [config.uniswapMarket]);
        const newObservation = await call(uniswapView, 'newObservations', [config.uniswapMarket]);
        expect(oldObservation.timestamp).numEquals(newObservation.timestamp);
        expect(oldObservation.acc).numEquals(newObservation.acc);
        if (config.priceSource != PriceSource.TWAP) {
          expect(oldObservation.acc).numEquals(0);
          expect(newObservation.acc).numEquals(0);
          expect(oldObservation.timestamp).numEquals(0);
          expect(newObservation.timestamp).numEquals(0);
        }
      }))
    });
  })
});
