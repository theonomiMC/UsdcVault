![CI](https://github.com/theonomiMC/usdcvault/actions/workflows/CI.yml/badge.svg) ![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg) ![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDE00.svg) ![Coverage](https://img.shields.io/badge/Coverage-97.5%25-brightgreen.svg)


# 🏛️ UsdcVault

A USDC vault built on ERC-4626. Written as a learning project to understand how production vaults handle fees, share price accounting, and invariant testing.

---

## 🚀 Getting Started

### Prerequisites

Ensure you have [Foundry](https://book.getfoundry.sh/getting-started/installation) installed on your machine.

### Installation

```bash
git clone https://github.com/theonomiMC/UsdcVault.git
cd usdc-vault
forge install
```

---

## ⚙️ What it does

Depositors put USDC in, get vault shares back. Shares accrue value as yield enters the vault. Two fee mechanisms:

- **0.5% withdrawal fee** — taken on every exit, kept inside the vault until the owner claims it
- **10% performance fee** — minted as shares to the owner, only when the share price hits a new all-time high (high water mark)

The withdrawal fee uses a gross/net model. When you call `withdraw(100)`, you get exactly 100 USDC out. The vault burns enough extra shares to cover the fee — you don't have to think about it. `redeem(shares)` works the opposite way: you burn a fixed number of shares and receive gross minus fee.

---

## 📊 Fee accounting

`totalAssets()` excludes accumulated withdrawal fees:

```
totalAssets = balanceOf(vault) - accumulatedFees
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

The test suite has two layers:

**Unit tests** — one function at a time, fee math verification, access control,
and edge cases.

**Invariant tests** — a stateful fuzzer runs random sequences of deposit,
withdraw, redeem, mint, and fee claim operations. After each call,
four invariants are checked:

```
totalAssets + accumulatedFees == balanceOf(vault)
totalSupply == sum of all share balances
HWM never decreases
sharePrice > 0 when supply exists
```

**Coverage** (measured on `src/` only — test helpers and scripts excluded):

| Metric    | Rate  |
| --------- | ----- |
| Lines     | 97.5% |
| Functions | 95.0% |

The two uncovered items are `getDecimalsOffset()` (a trivial view wrapper)
and one internal handler helper — neither affects correctness.

```
totalAssets + accumulatedFees == balanceOf(vault)
totalSupply == sum of all share balances
HWM never decreases
sharePrice > 0 when supply exists
```

Passed **200,000** calls across 1,000 random sequences with **no violations**.

---

## Running tests

```bash
# unit + fuzz
forge test

# invariant suite
forge test --match-contract UsdcVaultInvariants

# coverage
forge coverage --report lcov
genhtml lcov.info -o coverage/
open coverage/index.html
```

---

## Roadmap / Future Work

Strategy integration — the vault currently holds USDC directly. The next step is connecting it to a yield source (Aave, Compound, etc.) with an idle buffer that keeps a percentage liquid and pushes the rest to the strategy after deposits.

---

## Dependencies

- OpenZeppelin Contracts v5
- Foundry
