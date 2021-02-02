function address(n) {
  return `0x${n.toString(16).padStart(40, '0')}`;
}

function keccak256(str) {
  return web3.utils.keccak256(str);
}

function uint(n) {
  return web3.utils.toBN(n).toString();
}

describe('UniswapConfig', () => {
  it('basically works', async () => {
    const ETH = await deploy('MockCToken', [address(0)])
    const BTC = await deploy('MockCToken', [address(3)])
    const unlistedButUnderlying = await deploy('MockCToken', [address(4)])
    const unlistedNorUnderlying = await deploy('MockCToken', [address(5)])
    const contract = await deploy('UniswapConfig', [[
      {underlying: address(0), symbolHash: keccak256('ETH'), baseUnit: uint(1e18), priceSource: 0, fixedPrice: 0, uniswapMarket: address(6), isUniswapReversed: false},
      {underlying: address(3), symbolHash: keccak256('BTC'), baseUnit: uint(1e18), priceSource: 1, fixedPrice: 1, uniswapMarket: address(7), isUniswapReversed: true},
      {underlying: address(4), symbolHash: keccak256('REP'), baseUnit: uint(1e18), priceSource: 1, fixedPrice: 1, uniswapMarket: address(7), isUniswapReversed: true}
    ], false]);

    const cfg0 = await call(contract, 'getTokenConfig', [0]);
    const cfg1 = await call(contract, 'getTokenConfig', [1]);
    const cfg2 = await call(contract, 'getTokenConfig', [2]);
    const cfgCT0 = await call(contract, 'getTokenConfigByCToken', [ETH._address]);
    const cfgCT1 = await call(contract, 'getTokenConfigByCToken', [BTC._address]);
    const cfgU2 =  await call(contract, 'getTokenConfigByCToken', [unlistedButUnderlying._address])
    expect(cfg0).toEqual(cfgCT0);
    expect(cfg1).toEqual(cfgCT1);
    expect(cfg0).not.toEqual(cfg1);
    expect(cfgU2).toEqual(cfg2);

    await expect(call(contract, 'getTokenConfig', [3])).rejects.toRevert('revert token config not found');
    await expect(call(contract, 'getTokenConfigByCToken', [address(3)])).rejects.toRevert('revert'); // not a ctoken
    await expect(call(contract, 'getTokenConfigByCToken', [unlistedNorUnderlying._address])).rejects.toRevert('revert token config not found');
  });

  it('returns configs exactly as specified', async () => {
    const symbols = Array(30).fill(0).map((_, i) => String.fromCharCode('a'.charCodeAt(0) + i));
    const configs = symbols.map((symbol, i) => {
      return {underlying: address(i), symbolHash: keccak256(symbol), baseUnit: uint(1e6), priceSource: 0, fixedPrice: 1, uniswapMarket: address(i + 50), isUniswapReversed: i % 2 == 0}
    });
    var cToken = [];
    for (var i = 0; i < configs.length; i++) cToken[i] = (await deploy('MockCToken', [configs[i].underlying]))._address;
    const contract = await deploy('UniswapConfig', [configs, false]);

    await Promise.all(configs.map(async (config, i) => {
      const cfgByIndex = await call(contract, 'getTokenConfig', [i]);
      const cfgByCToken = await call(contract, 'getTokenConfigByCToken', [cToken[i]]);
      const cfgByUnderlying = await call(contract, 'getTokenConfigByUnderlying', [address(i)]);
      expect({
        underlying: cfgByIndex.underlying.toLowerCase(),
        symbolHash: cfgByIndex.symbolHash,
        baseUnit: cfgByIndex.baseUnit,
        priceSource: cfgByIndex.priceSource,
        fixedPrice:  cfgByIndex.fixedPrice,
        uniswapMarket: cfgByIndex.uniswapMarket.toLowerCase(),
        isUniswapReversed: cfgByIndex.isUniswapReversed
      }).toEqual({
        underlying: config.underlying,
        symbolHash: config.symbolHash,
        baseUnit: `${config.baseUnit}`,
        priceSource: `${config.priceSource}`,
        fixedPrice: `${config.fixedPrice}`,
        uniswapMarket: config.uniswapMarket,
        isUniswapReversed: config.isUniswapReversed
      });
      expect(cfgByIndex).toEqual(cfgByCToken);
      expect(cfgByIndex).toEqual(cfgByUnderlying);
    }));
  });

  it('checks gas', async () => {
    const configs = Array(26).fill(0).map((_, i) => {
      const symbol = String.fromCharCode('a'.charCodeAt(0) + i);
      return {
        underlying: address(i + 1),
        symbolHash: keccak256(symbol),
        baseUnit: uint(1e6),
        priceSource: 0,
        fixedPrice: 1,
        uniswapMarket: address(i + 50),
        isUniswapReversed: i % 2 == 0}
    });
    var cToken = [];
    for (var i = 0; i < configs.length; i++) cToken[i] = (await deploy('MockCToken', [configs[i].underlying]))._address;
    const contract = await deploy('UniswapConfig', [configs, false]);

    const cfg9 = await call(contract, 'getTokenConfig', [9]);
    const tx9 = await send(contract, 'getTokenConfig', [9]);
    expect(cfg9.underlying).addrEquals(address(10));
    expect(tx9.gasUsed).toEqual(28893);

    const cfg25 = await call(contract, 'getTokenConfig', [25]);
    const tx25 = await send(contract, 'getTokenConfig', [25]);
    expect(cfg25.underlying).addrEquals(address(26));
    expect(tx25.gasUsed).toEqual(28893);

    const cfgCT26 = await call(contract, 'getTokenConfigByCToken', [cToken[25]]);
    const txCT26 = await send(contract, 'getTokenConfigByCToken', [cToken[25]]);
    expect(cfgCT26.underlying).addrEquals(address(26));
    expect(txCT26.gasUsed).toEqual(34130);

    const cfgU26 = await call(contract, 'getTokenConfigByUnderlying', [address(26)]);
    const txU26 = await send(contract, 'getTokenConfigByUnderlying', [address(26)]);
    expect(cfgU26.underlying).addrEquals(address(26));
    expect(txU26.gasUsed).toEqual(31057);
  });
});