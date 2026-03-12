![CI](https://github.com/theonomiMC/usdcvault/actions/workflows/CI.yml/badge.svg) ![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg) ![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDE00.svg) ![Coverage](https://img.shields.io/badge/Coverage-98%25-brightgreen.svg)

# 🏛️ UsdcVault V2 — Upgradeable

A USDC vault built on ERC-4626 with UUPS upgradeability and strategy integration.
Written as a learning project to understand upgradeable proxies, storage layout,
and yield strategy patterns.

## [Live Demo](https://usdc-vault-ui.vercel.app/)

---

## 🚀 Getting Started

### Prerequisites

Ensure you have [Foundry](https://book.getfoundry.sh/getting-started/installation) installed on your machine.

### Installation

```bash
git clone https://github.com/theonomiMC/UsdcVault.git
cd UsdcVault
forge install
```

---

## ⚙️ What it does

Depositors put USDC in, get vault shares back. Shares accrue value as yield enters the vault. Two fee mechanisms:

- **0.5% withdrawal fee** — taken on every exit, kept inside the vault until the owner claims it
- **10% performance fee** — minted as shares to the owner, only when the share price hits a new all-time high (high water mark)
- **Strategy integration** — idle funds can be invested into a yield strategy.
  The vault pulls from the strategy automatically when a withdrawal exceeds
  the vault's idle balance.

The withdrawal fee uses a gross/net model. When you call `withdraw(100)`, you get exactly 100 USDC out. The vault burns enough extra shares to cover the fee — you don't have to think about it. `redeem(shares)` works the opposite way: you burn a fixed number of shares and receive gross minus fee.

---

## 📊 Fee accounting

`totalAssets()` excludes accumulated withdrawal fees:

```
totalAssets = balanceOf(vault) + strategy.totalAssets() - accumulatedFees

(strategy term is 0 when no strategy is set)
```

This keeps the share price honest. Fees sitting in the vault belong to the owner, not depositors, so they're excluded from yield calculations. The owner calls `claimFees()` to pull them out.

---

## 📈 Performance fee / high water mark

The vault tracks the highest share price ever seen. When the price exceeds that mark, the protocol takes 10% of the gain by minting new shares to the owner.

The high water mark is updated to the **post-mint** price, not pre-mint. This matters because minting fee shares slightly dilutes everyone, dropping the price. Setting HWM to pre-mint would let the protocol collect fees again on what is essentially the same price level.

```
price before mint: 1.20e18
fee shares minted → price drops to: 1.1901e18
HWM set to:        1.1901e18  ← not 1.20e18
```

---

## Architecture notes

All exit logic runs through `_withdraw()`. Both `withdraw()` and `redeem()` delegate to it, so any future change (like pulling liquidity from a strategy) only needs to go in one place.

Virtual shares use a 3-decimal offset to mitigate the ERC-4626 inflation attack that affects vaults with low initial liquidity.

Ownership uses `Ownable2Step` — transferring ownership requires the new owner to explicitly accept, which prevents accidental transfers to wrong addresses.

---

## Testing

The test suite has three layers:

**Unit tests** — one function at a time, fee math verification, access control,
and edge cases. Covers both V1 and V2 upgrade path.

**Upgrade tests** — verifies that state (shares, HWM, fees) survives the V1→V2
upgrade with no corruption.

**Invariant tests** — a stateful fuzzer runs random sequences of deposit,
withdraw, redeem, mint, invest, and fee claim operations.
After each call, three invariants are checked:
```
totalAssets + accumulatedFees == balanceOf(vault) + strategy.totalAssets()
HWM never decreases below 1e18
sharePrice >= 0 when supply exists
```

**Coverage** (measured on `src/` only — test helpers and scripts excluded):

| Metric     | Rate   |
|------------|--------|
| Lines      | 100%   |
| Statements | 99%    |
| Branches   | 93.75% |
| Functions  | 100%   |

Passed **200,000** calls across **1,000** sequences at **200** calls deep
with **no violations**.

---

## Running tests

```bash
# unit + fuzz
forge test

# invariant suite
forge test --match-contract UsdcVaultV2Invariants

# coverage
forge coverage --report lcov
genhtml lcov.info -o coverage/
open coverage/index.html
```

---


## Roadmap

- ✅ Strategy integration — completed in V2
- ✅ Frontend — Next.js + wagmi + RainbowKit

---

## Dependencies

- OpenZeppelin Contracts v5
- Foundry

---


## Deployments (Sepolia)

| Contract       | Address                                      | Notes                     |
|----------------|----------------------------------------------|---------------------------|
| UsdcVault      | 0x6E3302b5C8919591A347FB0e49425F6120c39a58   | Non-upgradeable original  |
| Proxy (V1→V2)  | 0x3D0dDdCCdCA542AB2aB1D1d328F4e4344a330589   | Always use this address   |
| V1 Impl        | 0x46889EA2f428CfaA4a5179D4b785A97ceB7675D6   | Do not interact directly  |
| V2 Impl        | 0xEb19A187346f4f2343E83249652377dD3eD9D038   | Do not interact directly  |