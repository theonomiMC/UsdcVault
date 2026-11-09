![CI](https://github.com/theonomiMC/usdcvault/actions/workflows/CI.yml/badge.svg) ![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg) ![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDE00.svg) ![Branch Coverage](https://img.shields.io/badge/Branch_Coverage-90.48%25-green.svg)

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


## Roadmap

- ✅ Strategy integration — completed in V2
- ✅ Frontend — Next.js + wagmi + RainbowKit

---

## Dependencies

- OpenZeppelin Contracts v5
- Foundry

---


## Deployed contracts (Sepolia)
| Contract | Address | Notes |
|---|---|---|
| Proxy (V1 → V2) | `0x3D0dDdCCdCA542AB2aB1D1d328F4e4344a330589` | Always use this address. It did not change. |
| V2 implementation (current) | `0xEDfd1C6d1bC3DcdceDa0008E7EcF292592701915` | Contains the security fixes. Verified on Etherscan. |
| V2 implementation (old) | `0xEb19A187346f4f2343E83249652377dD3eD9D038` | Deprecated. Has known vulnerabilities. Do not use. |
| V1 implementation | `0x46889EA2f428CfaA4a5179D4b785A97ceB7675D6` | The first implementation. The proxy does not use it any more. |
| UsdcVault | `0x6E3302b5C8919591A347FB0e49425F6120c39a58` | Non-upgradeable original. Not part of this security review. |


## Security review and fixes

The vault was reviewed and tested before the upgrade. These problems were found and fixed:

1. **Missing allowance check (critical).** `withdraw` and `redeem` did not check the allowance when someone acted for another owner. Anyone could withdraw another user's funds. The check is now in place.
2. **Changing the strategy could hide funds (medium).** `setStrategy` only changed the pointer, so funds stayed in the old strategy and the share price dropped. Now it pulls all funds back from the old strategy first and checks that the new strategy uses the same asset.
3. **`redeem` of all shares could fail (medium).** In some cases `redeem(balance)` reverted, and rounding could burn the wrong number of shares. V2 now burns exactly the shares that are requested.
4. **High-water mark could go down (low).** In a very rare case (almost no shares left) the performance fee high-water mark could decrease. It can now only go up.

### Behaviour changes

- `setStrategy` moves all funds back to the vault. The owner must call `invest` again to use the new strategy.
- `withdraw` and `redeem` now revert with `InsufficientLiquidity` if the strategy cannot return enough funds. Before, they could pay less without an error.

### Known limits

- One owner controls upgrades, pause and strategy changes. Users must trust this owner. This is a testnet project, so a multisig is not used.
- `previewRedeem` and similar functions do not include a performance fee that is still waiting to be collected, so the real result can be slightly lower.


## Tests

**Coverage** (measured on `src/` only — tests, mocks and scripts excluded;
Sepolia fork test excluded from execution):

| Metric     | Rate    |
|------------|---------|
| Lines      | 100%    |
| Statements | 98.73%  |
| Branches   | 90.48%  |
| Functions  | 100%    |

Coverage measured using Foundry with reduced invariant runs (50 runs × 30 depth). The full invariant test suite runs separately with its standard configuration.

- Unit tests for V1 and V2.
- Upgrade tests - verify that the V1 -> V2 upgrade preserves existing vault state, including shares, fees, and the high water mark.
- Stateful fuzzing of vault operations and accounting properties.
- Sepolia upgrade verification - `test/audit/SepoliaUpgradeCheck.t.sol` validates the deployed upgrade against Sepolia state.

The upgrade verification test provides an additional check of the deployed proxy and implementation, complementing local upgrade tests.

Run everything with:

```bash
# Unit and fuzz tests
make test

# Invariant tests
forge test --match-contract UsdcVaultV2Invariants

# Sepolia deployment verification (fork)
forge test \
  --match-path test/audit/SepoliaUpgradeCheck.t.sol \
  --fork-url "$SEPOLIA_RPC_URL" \
  -vvv

# Coverage (src/ only, Sepolia fork test excluded)
make coverage
```
