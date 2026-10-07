# Vendored libraries

Only the files this repository imports, so it builds offline.

- `v4-core/`: Uniswap v4 core, the version the team's other Robinhood Chain contracts build against. Interfaces, types and
  libraries are MIT; `PoolManager.sol` and its base contracts are BUSL-1.1 (see `v4-core/licenses/`) and are used by
  the tests only, never deployed by this repository.
- `v4-periphery/`: `BaseHook`, `ImmutableState`, `IImmutableState` (MIT, `v4-periphery/LICENSE`).
- `solady/`: `Ownable`, `ReentrancyGuard`, `SafeTransferLib` (MIT, github.com/Vectorized/solady).
- `forge-std/`: tests only (MIT / Apache-2.0).
- `solmate/src/auth/Owned.sol`: not solmate's. v4-core's PoolManager imports solmate's `Owned`, which is AGPL; this is
  a minimal stand-in with the same interface, written for these tests (MIT).
