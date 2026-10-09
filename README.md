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

The coin is launched by the swarm's Pons launcher (launch #1026, `0xE0aBb21F15766BE162429f46F494617eB5EF6Ba0`,
magic0xfrens/imd6900-pons-launch), at `0x69005D86d2c1bb1dFE70Df48e27D6aa02D044149`. Its `launch(salt, coin, 2 ether,
minOut)` dev-buys with 2 ETH of what the old IMDSTR pool's pull sent it and refunds the rest to the team wallet. That
refund opens this pool. `script/Owner.s.sol` runs the steps from the team wallet:

1. `open(<pool>, <wei>)`: releases from the launcher the coin worth `<wei>` at the Pons curve's price (the coin beyond
   one per IMDSTR, which no holder can claim), and opens the pool at that price with the ETH.
2. `wire(<pool>)`: the coin's creator fees split 70% pot bridge, 10% this pool (its `compound` turns them into depth),
   20% the team; the pool's fee sink is the launcher.
3. Deploy the perps engine and its vault against the open pool, then `hook.setPerpEngine(engine)` and
   `pool.setPerpEngine(engine)`.
4. Hand both to the Robinhood timelock (`transferOwnership`).

**The liquidity always comes back.** The pool contract owns all of it and its owner can take it all out with
`removeLiquidity`; the hook only checks that the caller is the pool and the range is full, so no hook state can stop
it. The one guard is the pool's own engine check (no withdrawal that leaves an open position liquidatable), which the
owner can switch off with `pool.setPerpEngine(address(0))`. The hook is not upgradeable on purpose: a proxy needs
DELEGATECALL, which IMD's admission refuses, and an upgradeable hook would let one key change everyone's trading rules.
A new hook is a new launch: take the liquidity out, open the new pool with it.

`test/RobinhoodFlow.fork.t.sol` (needs `ROBINHOOD_RPC_URL`) runs all of it on live Robinhood state: the launcher's
2 ETH dev buy (525.7M coins, 0.8283 ETH refunded, 205.6M releasable), this launch as the swarm deploys it, the pool
opened at the Pons price, trades through the hook and the band, the fee split feeding the pool, the owner taking all
the liquidity back past a blocking and a broken engine, and a second hook opened with the same money. Pons taxes buys
in the coin's launch block ~99% (anti-sniper; the launcher's own buy is exempt), 6.9% after.

## Admission (what IMD checks, and the tests that check it first)

`forge test`, offline, no RPC:

- `test_DeploysOnAFreshChain`: the launch deploys where nothing it names exists (IMD deploys a launch on a fresh chain
  first); the hook's address carries its flags, the pool and the hook name each other, both are the owner's.
- `test_FitsOneTransaction`: the whole launch, the mining included, under EIP-7825's 2^24 gas. The mining depends on
  the deployer's address: over 40 addresses it took ~17k tries on average at ~128 gas each (5.9M gas mean, 10.5M the
  worst); the cap leaves room for ~95k tries, which one deployer in ~350 would need.
- `test_EachDeployerMinesItsOwnSalt`: whatever address deploys it, it finds its own salt.
- `test_PassesTheAdmissionScan`: no contract's code shows CALLCODE, DELEGATECALL or SELFDESTRUCT (PUSH data skipped).
- `test_RefusesADynamicFee`: a dynamic fee would cost the pool Uniswap's automatic routing; the hook refuses it.
- `test/IMD6900Perps.t.sol`, against a real v4 PoolManager (vendored, tests only): the pool opens at the Pons price,
  trades both ways, refuses a trade that would leave it more than 30% from Pons, refuses anyone else's liquidity, only
  the owner opens it and takes liquidity out, anyone deepens it, and perps stay off until an engine is set.

Every library is vendored under `lib/` (only the files imported), so it builds offline: see `lib/README.md`.
