<div align="center">

# 🏦 Decentralized Stablecoin (DSC) Protocol

<h3>A next-generation DeFi stablecoin protocol — trustless, transparent, and fully on-chain</h3>

![Solidity](https://img.shields.io/badge/Solidity-0.8.20-363636?style=for-the-badge&logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-Framework-FFDB1C?style=for-the-badge&logo=ethereum&logoColor=black)
![Chainlink](https://img.shields.io/badge/Chainlink-Oracles-375BD2?style=for-the-badge&logo=chainlink&logoColor=white)
![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-Security-4E5EE4?style=for-the-badge&logo=openzeppelin&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

---

**DSC** is a robust, elegantly engineered DeFi protocol that brings the power of **exogenous, crypto-collateralized, algorithmically stable** money to the Ethereum ecosystem. Inspired by the battle-tested architecture of MakerDAO's DAI system, DSC delivers a streamlined, gas-efficient stablecoin experience — no governance overhead, no stability fees, just clean and reliable decentralized finance backed by **WETH** and **WBTC**.

<br/>

```
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   💰  Deposit WETH/WBTC  ──►  🏗️  Mint DSC  ──►  💵  1 USD  ║
║                                                              ║
║        Fully Collateralized  •  Algorithmically Stable       ║
║           Trustless  •  Permissionless  •  On-Chain           ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

</div>

---

## 📑 Table of Contents

- [🔭 Overview](#-overview)
- [🧠 Core Concepts](#-core-concepts)
  - [Stablecoin Classification](#stablecoin-classification)
  - [Overcollateralization](#overcollateralization)
  - [Health Factor](#health-factor)
  - [Liquidation Mechanism](#liquidation-mechanism)
  - [Oracle Safety](#oracle-safety)
- [🏗️ Architecture](#️-architecture)
  - [Smart Contracts](#smart-contracts)
  - [Contract Interaction Flow](#contract-interaction-flow)
- [✨ Features](#-features)
- [⚙️ Protocol Parameters](#️-protocol-parameters)
- [📁 Folder Structure](#-folder-structure)
- [🚀 Getting Started](#-getting-started)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Build](#build)
  - [Deploy](#deploy)
- [🧪 Testing](#-testing)
  - [Unit Tests](#unit-tests)
  - [Fuzz / Invariant Tests](#fuzz--invariant-tests)
  - [Running Tests](#running-tests)
- [⚠️ Known Limitations](#️-known-limitations)
- [📦 Dependencies](#-dependencies)

---

## 🔭 Overview

The Decentralized Stablecoin (DSC) protocol empowers users to unlock the value of their crypto assets by depositing **WETH** or **WBTC** as collateral and minting **DSC** — a rock-solid ERC-20 stablecoin pegged to **$1 USD**. The system maintains its peg through robust overcollateralization (200% minimum) and smart economic liquidation incentives, all without relying on any central authority, governance token, or trusted third party.

> 💡 **TL;DR** — Deposit crypto → Mint stablecoins → Stay overcollateralized → Enjoy DeFi freedom.

**How it works at a high level:**

```
  ┌──────────┐          ┌──────────────┐          ┌───────────┐
  │  Step 1  │          │    Step 2    │          │  Step 3   │
  │ 💰 Deposit│  ──────► │ 🏗️ Mint DSC  │  ──────► │ 💵 Use DSC │
  │ WETH/WBTC│          │ (up to 50%)  │          │ Anywhere! │
  └──────────┘          └──────────────┘          └───────────┘
```

1. 📥 A user deposits WETH or WBTC into the `DSCEngine` contract.
2. 📊 Based on the USD value of their collateral (fetched via Chainlink price feeds), they can mint DSC tokens up to 50% of their collateral value.
3. ⚡ If a user's collateral value drops (due to price movement) and their position becomes undercollateralized, anyone can liquidate them — repaying their DSC debt in exchange for their collateral plus a 10% bonus.
4. 🔓 Users can repay (burn) their DSC debt at any time and withdraw their collateral with zero fees.

---

## 🧠 Core Concepts

### 📋 Stablecoin Classification

| Property | Value |
|---|---|
| 🔗 **Collateral Type** | Exogenous (backed by external assets: WETH, WBTC) |
| ⚖️ **Stability Mechanism** | Algorithmic (overcollateralization + liquidation incentives) |
| 🎯 **Peg** | Anchored to 1 USD |
| 🏭 **Minting** | Decentralized — anyone can mint by depositing collateral |

### 🛡️ Overcollateralization

The protocol enforces a **minimum 200% collateralization ratio** at all times — a powerful safety margin that keeps the system rock-solid. For every $1 of DSC minted, the user must maintain at least $2 worth of collateral.

```
Example:
  Collateral deposited: 5 ETH × $2,000/ETH = $10,000
  Maximum DSC mintable: $10,000 × 50% = 5,000 DSC
  Collateralization ratio: $10,000 / $5,000 = 200%
```

This generous buffer creates a strong safety net, protecting the protocol from insolvency during normal market volatility and giving users ample room to manage their positions.

### 💓 Health Factor

The **health factor** is the protocol's core solvency metric, computed per user:

```
Health Factor = (Collateral Value in USD × Liquidation Threshold / 100 × 1e18) / Total DSC Minted
```

- ✅ **Health Factor ≥ 1.0** → Position is safe
- ❌ **Health Factor < 1.0** → Position is undercollateralized and eligible for liquidation
- 🟢 **Health Factor = max(uint256)** → User has no debt (can never be liquidated)

```
Example:
  Collateral: $10,000 | Debt: 4,000 DSC
  HF = ($10,000 × 50/100) × 1e18 / 4,000e18 = 1.25e18 (safe — above 1.0)

  Collateral: $10,000 | Debt: 6,000 DSC
  HF = ($10,000 × 50/100) × 1e18 / 6,000e18 = 0.83e18 (liquidatable — below 1.0)
```

The health factor is diligently checked after every state-changing operation (deposit, mint, redeem, burn, liquidate) to ensure no action ever leaves a user undercollateralized — a continuous safety guarantee.

### ⚡ Liquidation Mechanism

When a user's health factor drops below 1.0, their position can be **partially or fully liquidated** by any external actor (typically MEV bots or liquidation bots). This creates a powerful economic incentive layer that keeps the entire system healthy:

```
  🔍 Monitor  ──►  💸 Repay Debt  ──►  🎁 Collect Bonus  ──►  ✅ System Healed
```

1. 🔍 **Liquidator identifies** an undercollateralized position (health factor < 1.0).
2. 💸 **Liquidator repays** some or all of the user's DSC debt.
3. 🎁 **Liquidator receives** the equivalent collateral value **plus a 10% bonus**.
4. ✅ The protocol verifies the liquidation **improved** the user's health factor.
5. 🛡️ The protocol verifies the **liquidator's own** health factor is still healthy.

```
Example:
  User has 10 ETH ($180 total at $18/ETH) backing 100 DSC debt
  Liquidator covers 100 DSC → receives $110 worth of ETH (100 + 10% bonus)
  User's debt: 100 → 0 DSC
  User's collateral: reduced by ~6.11 ETH
```

### 🔮 Oracle Safety

The protocol leverages **Chainlink's industry-leading price feeds** for real-time, tamper-resistant USD price data. A custom `OracleLib` library wraps every price feed call with an intelligent **staleness check**:

- ⏰ If a price feed hasn't updated within **3 hours**, all protocol operations safely pause.
- 🚫 This prevents the protocol from ever operating on stale or incorrect price data.
- 🎯 **Design philosophy:** Safety first — the protocol intentionally freezes rather than risking operations on bad data.

---

## 🏗️ Architecture

### 📜 Smart Contracts

| Contract | Description |
|---|---|
| 🔧 **`DSCEngine.sol`** | Core protocol engine. Manages collateral deposits/withdrawals, DSC minting/burning, liquidations, and health factor enforcement. Owns minting privileges over the DSC token. |
| 💵 **`DecentralizedStableCoin.sol`** | ERC-20 stablecoin token (symbol: `DSC`). Extends OpenZeppelin's `ERC20Burnable` and `Ownable`. Only the owner (`DSCEngine`) can mint and burn tokens. |
| 🔮 **`OracleLib.sol`** | Library that wraps Chainlink's `AggregatorV3Interface` with a staleness check. Reverts if price data is older than 3 hours. |
| 🚀 **`DeployDSC.s.sol`** | Foundry deployment script. Deploys DSC token, DSCEngine, and transfers DSC ownership to the engine. |
| ⚙️ **`HelperConfig.s.sol`** | Network configuration script. Provides price feed and token addresses for Sepolia testnet or local Anvil (with mocks). |

### 🔄 Contract Interaction Flow

```
 ┌─────────────────────────────────────────────────────────────────────┐
 │                    🏦  DSC PROTOCOL ARCHITECTURE                    │
 └─────────────────────────────────────────────────────────────────────┘

 ┌──────────────┐     💰 deposits WETH/WBTC     ┌──────────────────┐
 │              │ ────────────────────────────► │                  │
 │  👤 User     │     🪙 mints/burns DSC         │  🔧 DSCEngine    │
 │              │ ◄────────────────────────────►│   (Core Logic)   │
 └──────────────┘                               │                  │
                                                │  📦 Collateral   │
 ┌──────────────┐     ⚡ liquidates position     │     Management   │
 │  🤖 Liquidator│ ────────────────────────────► │  💓 Health Factor│
 │    (Bot)     │ ◄──── 🎁 collateral + bonus   │  ⚡ Liquidation   │
 └──────────────┘                               └────────┬─────────┘
                                                         │
                                         ┌───────────────┼───────────────┐
                                         ▼               ▼               ▼
                                 ┌──────────────┐ ┌────────────┐ ┌────────────────┐
                                 │ 🔮 Chainlink │ │ 💵 DSC     │ │ 🪙 WETH/WBTC  │
                                 │  Price Feeds │ │   Token    │ │  (Collateral)  │
                                 │ via OracleLib│ │  (ERC-20)  │ │                │
                                 └──────────────┘ └────────────┘ └────────────────┘
```

---

## ✨ Features

| | Feature | Description |
|---|---|---|
| 📥 | **Deposit Collateral** | Deposit WETH or WBTC into the protocol as collateral |
| 🪙 | **Mint DSC** | Mint USD-pegged stablecoins against deposited collateral (up to 50% of collateral value) |
| ⚡ | **Deposit & Mint (Atomic)** | Deposit collateral and mint DSC in a single transaction for gas savings and atomicity |
| 🔥 | **Burn DSC** | Repay DSC debt to improve health factor or prepare for collateral withdrawal |
| 📤 | **Redeem Collateral** | Withdraw collateral (only if health factor remains ≥ 1.0 after withdrawal) |
| 🔄 | **Redeem & Burn (Atomic)** | Burn DSC and redeem collateral in a single transaction |
| ⚡ | **Liquidation** | Liquidate undercollateralized positions and earn a 10% collateral bonus |
| ✂️ | **Partial Liquidation** | Liquidators can cover partial debt amounts, not just full positions |
| 🏦 | **Multi-Collateral Support** | Deposit both WETH and WBTC simultaneously; total collateral value is aggregated |
| 🔮 | **Stale Price Protection** | OracleLib freezes the protocol if Chainlink feeds go stale (>3 hours) |
| 🛡️ | **Reentrancy Protection** | All state-changing functions use OpenZeppelin's `ReentrancyGuard` |
| 🔒 | **CEI Pattern** | All functions follow Checks-Effects-Interactions to prevent reentrancy exploits |
| 🌐 | **Multi-Network Deployment** | Deployment scripts support Sepolia testnet and local Anvil with mock contracts |

---

## ⚙️ Protocol Parameters

| Parameter | Value | Description |
|---|---|---|
| `LIQUIDATION_THRESHOLD` | 50 | Collateral counted at 50% → enforces 200% overcollateralization |
| `LIQUIDATION_BONUS` | 10 | Liquidators receive 10% extra collateral as incentive |
| `LIQUIDATION_PRECISION` | 100 | Denominator for percentage math |
| `MIN_HEALTH_FACTOR` | 1e18 | 1.0 in 18-decimal fixed-point; positions below this are liquidatable |
| `PRECISION` | 1e18 | Standard 18-decimal precision (matches ETH wei) |
| `ADDITIONAL_FEED_PRECISION` | 1e10 | Scales Chainlink 8-decimal prices to 18 decimals |
| `FEED_PRECISION` | 1e8 | Chainlink's native 8-decimal precision |
| Oracle Staleness Timeout | 3 hours | Maximum age for price feed data before protocol freezes |

---

## 📁 Folder Structure

```
Stablecoin/
├── foundry.toml                          # Foundry config (remappings, invariant settings, profiles)
├── README.md                             # This file
├── report.md                             # Audit / analysis report
│
├── src/                                  # Source contracts
│   ├── DecentralizedStableCoin.sol       # ERC-20 DSC token (mintable/burnable, owned by DSCEngine)
│   ├── DSCEngine.sol                     # Core engine (collateral, minting, liquidation logic)
│   └── libraries/
│       └── OracleLib.sol                 # Chainlink price feed wrapper with staleness check
│
├── script/                               # Deployment scripts
│   ├── DeployDSC.s.sol                   # Deploys DSC + DSCEngine, transfers ownership
│   └── HelperConfig.s.sol                # Network config (Sepolia addresses or Anvil mocks)
│
├── test/                                 # Test suite
│   ├── unit/                             # Unit tests (isolated function-level testing)
│   │   ├── DSCEngineTest.t.sol           # 40+ tests covering all DSCEngine functions
│   │   ├── DecentralizedStableCoinTest.t.sol  # Token mint/burn/transfer tests
│   │   └── OracleLibTest.t.sol           # Staleness check and price feed tests
│   │
│   ├── fuzz/                             # Fuzz & invariant tests (property-based testing)
│   │   ├── InvariantsTest.t.sol          # Core invariant: collateral >= DSC supply
│   │   ├── Handler.t.sol                 # Guided handler (valid call sequences only)
│   │   └── FailOnRevert.t.sol            # Loose handler (allows reverts, broader fuzzing)
│   │
│   └── mocks/                            # Mock contracts for local testing
│       ├── ERC20Mock.sol                 # Simplified ERC-20 for WETH/WBTC simulation
│       └── MockV3Aggregator.sol          # Chainlink AggregatorV3Interface mock
│
├── lib/                                  # External dependencies (git submodules)
│   ├── forge-std/                        # Foundry standard library
│   ├── openzeppelin-contracts/           # OpenZeppelin (ERC20, Ownable, ReentrancyGuard)
│   └── chainlink-brownie-contracts/      # Chainlink (AggregatorV3Interface)
│
└── cache/                                # Foundry build cache & invariant failure logs
```

---

## 🚀 Getting Started

### 📋 Prerequisites

- 🔨 [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- 🐙 [Git](https://git-scm.com/)

### 📥 Installation

```bash
git clone <repository-url>
cd Stablecoin
forge install
```

### 🔨 Build

```bash
forge build
```

### 🚀 Deploy

**🖥️ Local (Anvil):**

```bash
# Start local node
anvil

# Deploy (uses Anvil mock contracts automatically)
forge script script/DeployDSC.s.sol:DeployDSC --rpc-url http://localhost:8545 --broadcast
```

**🌐 Sepolia Testnet:**

```bash
# Set environment variable
export PRIVATE_KEY=<your_private_key>

# Deploy to Sepolia
forge script script/DeployDSC.s.sol:DeployDSC \
  --rpc-url <sepolia_rpc_url> \
  --broadcast \
  --verify
```

---

## 🧪 Testing

The test suite is structured into three rigorous layers to provide comprehensive coverage and rock-solid security guarantees.

```
 ╔═══════════════════════════════════════════════════════════╗
 ║                  🧪 TESTING PYRAMID                       ║
 ╠═══════════════════════════════════════════════════════════╣
 ║                                                           ║
 ║                    ╱  ╲        🔬 Invariant / Fuzz Tests  ║
 ║                   ╱    ╲       (Protocol-wide properties) ║
 ║                  ╱──────╲                                 ║
 ║                 ╱        ╲     🧩 Integration Tests       ║
 ║                ╱          ╲    (Multi-contract flows)     ║
 ║               ╱────────────╲                              ║
 ║              ╱              ╲   ✅ Unit Tests             ║
 ║             ╱________________╲  (Individual functions)    ║
 ║                                                           ║
 ╚═══════════════════════════════════════════════════════════╝
```

### ✅ Unit Tests

Located in `test/unit/`, these tests meticulously cover every public and external function in isolation.

**🔧 `DSCEngineTest.t.sol`** — 40+ tests across 9 categories:

| Category | # Tests | What's Verified |
|---|---|---|
| Constructor | 4 | Token-priceFeed pairing, collateral registration, DSC address |
| Price Feeds | 4 | USD value calculation for ETH and BTC, inverse conversion |
| Deposit Collateral | 6 | Zero amounts, unapproved tokens, balance updates, events, token transfers |
| Mint DSC | 5 | Zero amounts, no collateral, success, debt tracking, health factor enforcement |
| Burn DSC | 4 | Zero amounts, full/partial burn, over-burn revert |
| Deposit & Mint | 2 | Atomic operation success, health factor boundary |
| Redeem Collateral | 5 | Zero amounts, full/partial redemption, events, health factor enforcement |
| Redeem & Burn | 2 | Atomic operation, zero collateral revert |
| Liquidation | 4 | Healthy user revert, zero debt revert, bonus collateral, health factor improvement |
| Health Factor | 4 | No debt (max uint), with debt, at minimum, pure calculation |
| Getters | 8 | All view functions return correct values |

**💵 `DecentralizedStableCoinTest.t.sol`** — 12 tests:

| Category | What's Verified |
|---|---|
| Constructor | Name, symbol, owner correctness |
| Minting | Success, non-owner revert, zero address revert, zero amount revert, total supply |
| Burning | Success, non-owner revert, zero amount revert, over-burn revert, total supply reduction |
| Transfers | Standard transfer, approve + transferFrom |

**🔮 `OracleLibTest.t.sol`** — 6 tests:

| Category | What's Verified |
|---|---|
| Staleness | Correct data returned, revert after 3h, pass at exact 3h boundary |
| Edge Cases | Revert when `updatedAt = 0`, correct timeout value |
| Price Updates | Updated prices are correctly returned |

### 🔬 Fuzz / Invariant Tests

Located in `test/fuzz/`, these tests harness Foundry's powerful built-in fuzzer to verify **protocol-wide invariants** hold across thousands of randomized transaction sequences — providing mathematical confidence in the protocol's safety.

**🎯 Core Invariants Tested:**

1. 🛡️ **Overcollateralization Invariant** — The total USD value of all collateral held by the protocol must **always** be ≥ total DSC supply. This is the fundamental safety property.

2. 🔍 **Getter Stability Invariant** — All view/pure getter functions must **never revert**, regardless of protocol state.

3. 📊 **Accounting Invariant** — If DSC is in circulation, the protocol's collateral must cover at least 200% of that supply (matching the health factor requirement).

**🎲 Two Fuzzing Strategies:**

| Strategy | Files | `fail_on_revert` | Purpose |
|---|---|---|---|
| **Guided (Handler)** | `Handler.t.sol` + `InvariantsTest.t.sol` | `true` | Stateful handler bounds inputs and executes only valid call sequences. Proves no *valid* transaction sequence can break invariants. |
| **Loose (FailOnRevert)** | `FailOnRevert.t.sol` | `false` | Calls functions with loosely bounded random inputs, allowing reverts. Verifies invariants hold after any *successful* sequence. Broader exploration. |

**🤖 Handler Design (`Handler.t.sol`):**

The guided handler employs several smart strategies to maximize fuzzer effectiveness:

- 👻 **Ghost variables** — Track `timesDepositIsCalled`, `timesMintIsCalled`, and `timesRedeemIsCalled` for debugging and visibility into fuzzer behavior.
- 👥 **User tracking** — Maintains an array of addresses that have deposited collateral, ensuring `mintDsc()` and `redeemCollateral()` only target users with valid positions.
- 📏 **Bounded minting** — Calculates the maximum mintable DSC based on current collateral value and existing debt before calling `mintDsc()`.
- 🛡️ **Safe redemption** — Computes excess collateral above the 200% requirement before calling `redeemCollateral()`, preventing health factor violations.
- 🎲 **Collateral randomization** — Alternates between WETH and WBTC based on seed values to test both paths.

**⚙️ Fuzzer Configuration (`foundry.toml`):**

```toml
[invariant]
runs = 128         # Number of random call sequences
depth = 128        # Maximum calls per sequence
fail_on_revert = true

# Loose profile for FailOnRevert tests
[profile.loose.invariant]
runs = 128
depth = 128
fail_on_revert = false
```

### 🏃 Running Tests

```bash
# Run all tests
forge test

# Run with verbose output (shows traces on failure)
forge test -vvvv

# Run only unit tests
forge test --match-path test/unit/*

# Run only invariant tests (guided handler)
forge test --match-contract InvariantsTests

# Run loose invariant tests (fail-on-revert disabled)
FOUNDRY_PROFILE=loose forge test --match-contract FailOnRevertInvariants

# Run a specific test function
forge test --match-test testLiquidationSuccess -vvvv

# Generate gas report
forge test --gas-report
```

---

## ⚠️ Known Limitations

> These are intentional design trade-offs — each simplification keeps the protocol lean, auditable, and easy to reason about.

| # | Limitation | Details |
|---|---|---|
| 🌊 | **Black Swan Risk** | In a sudden, severe price crash where the protocol becomes ≤100% collateralized, liquidators have no economic incentive (no bonus to extract), potentially leaving bad debt in the system. |
| 🔮 | **Oracle Dependency** | The protocol is entirely dependent on Chainlink price feeds. If feeds become stale for >3 hours, the protocol safely pauses — a deliberate design choice (safety over availability). |
| 🪙 | **Limited Collateral Types** | Only WETH and WBTC are supported. Adding new collateral types requires redeployment. |
| 🏛️ | **No Governance** | Protocol parameters (liquidation threshold, bonus, etc.) are hardcoded as constants and cannot be changed after deployment. |
| 💸 | **No Stability Fee** | Unlike MakerDAO, there is no interest charged on minted DSC. Users can hold positions indefinitely at zero cost — a feature, not a bug! |
| ✂️ | **No Partial Liquidation Protection** | A liquidator could repeatedly partially liquidate a position, extracting bonus each time. |

---

## 📦 Dependencies

| | Library | Purpose |
|---|---|---|
| 🔨 | [Foundry / forge-std](https://github.com/foundry-rs/forge-std) | Testing framework, deployment scripting, cheatcodes |
| 🛡️ | [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | ERC20, ERC20Burnable, Ownable, ReentrancyGuard, IERC20 |
| 🔗 | [Chainlink Brownie Contracts](https://github.com/smartcontractkit/chainlink-brownie-contracts) | AggregatorV3Interface for price feed integration |

---

<div align="center">

**Built with ❤️ for the decentralized future**

⭐ Star this repo if you find it useful!

</div>