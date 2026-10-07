# IMD6900 perps hook: deployed by the IMD swarm on Robinhood Chain

The Uniswap v4 hook and pool behind IMD6900's in-pool perps on Robinhood Chain, packed so the IMD swarm can deploy
them with IMD's `evm_contracts` launch: one contract, constructor arguments only, nothing called after.

IMD6900 trades on Robinhood Chain as a Pons coin. This is its second market: an ETH / IMD6900 Uniswap v4 pool the
protocol owns in full, that its perps engine trades against, held near the coin's price on Pons.

- `src/IMD6900PerpHook.sol`: the hook. Before any swap that isn't the perps engine's own, it asks the engine to close
  every position that trade would sink, at the price before it moves; a sweep that can't finish reverts the trade (no
  bad debt outranks always-tradeable, with an owner escape hatch for a broken engine). After the swap it refuses to
  leave the pool further than `maxDeviationBps` (30%) from the coin's Pons price, unless the trade moved it closer. It
  uses no return deltas and no dynamic fee, so Uniswap's router quotes the pool on its own. Only its pool may
  initialize it or add and remove liquidity, full range only.
- `src/IMD6900PerpPool.sol`: the pool's one position. The owner opens it once the coin trades on Pons (the price, the
  ETH, the coin), anyone can deepen it, only the owner can take liquidity out and never while that would leave an open
  perps position liquidatable. The pool's static fee accrues to this position: the protocol earns it.
- `src/IMD6900PerpsLaunch.sol`: what the swarm deploys. Uniswap v4 reads a hook's permissions from the low 14 bits of
  its address, so the hook must sit at a mined address, and IMD deploys from its own deployer, which nobody can mine
  for in advance. So this constructor does it: it creates the pool, tries CREATE2 salts from itself until the hook's
  address carries exactly the hook's flags (one in 16,384 on average, done in assembly), creates the hook there, wires
  the pool to it and hands both to `owner`. It calls nothing that existed before it.

The perps engine (`PerpEngine`, `PerpVault`) is not in this launch: it reads the pool's live price when it is built,
so it comes after the pool opens, deployed by the owner and wired with `setPerpEngine` on the hook and the pool. Until
then the pool is spot only.

## The launch (`evm_contracts`, Robinhood Chain, chain id 4663)

One contract, `IMD6900PerpsLaunch`, with four constructor arguments, in order:

| | | |
|---|---|---|
| `poolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Uniswap v4's PoolManager on Robinhood Chain |
| `poolFee` | `10000` | the pool's static fee in hundredths of a bip (1%), the hook's too |
| `owner` | `0x35da9c0303507ddf708e87f2568eddf12c47a059` | the team wallet: runs the pool and the hook, later its timelock |
| `feeAddress` | `0x35da9c0303507ddf708e87f2568eddf12c47a059` | the hook's fee address (3% of any stray ETH it forwards) |

Read the deployed addresses from the launch contract: `pool()`, `hook()` and `salt()`.

## After the launch (the owner)

1. `pool.setFeeSink(<the coin's fee splitter>)`.
2. `pool.open(coin, curve, sqrtPriceX96, tokens)` with ETH: the coin, its Pons curve, the curve's price, and the coin
   to pair (approved first). What the price doesn't take comes back.
3. Deploy the perps engine and its vault against the open pool, then `hook.setPerpEngine(engine)` and
   `pool.setPerpEngine(engine)`.
4. Hand both to the Robinhood timelock (`transferOwnership`).

## Admission (what IMD checks, and the tests that check it first)

`forge test`, offline, no RPC:

- `test_DeploysOnAFreshChain`: the launch deploys where nothing it names exists (IMD deploys a launch on a fresh chain
  first); the hook's address carries its flags, the pool and the hook name each other, both are the owner's.
- `test_FitsOneTransaction`: the whole launch, the mining included, under EIP-7825's 2^24 gas.
- `test_EachDeployerMinesItsOwnSalt`: whatever address deploys it, it finds its own salt.
- `test_PassesTheAdmissionScan`: no contract's code shows CALLCODE, DELEGATECALL or SELFDESTRUCT (PUSH data skipped).
- `test_RefusesADynamicFee`: a dynamic fee would cost the pool Uniswap's automatic routing; the hook refuses it.
- `test/IMD6900Perps.t.sol`, against a real v4 PoolManager (vendored, tests only): the pool opens at the Pons price,
  trades both ways, refuses a trade that would leave it more than 30% from Pons, refuses anyone else's liquidity, only
  the owner opens it and takes liquidity out, anyone deepens it, and perps stay off until an engine is set.

Every library is vendored under `lib/` (only the files imported), so it builds offline: see `lib/README.md`.
