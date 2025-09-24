# Course-End Project 1 – Insurance Smart Contract

This project implements a **modular insurance system** on Ethereum using Solidity and OpenZeppelin standards.  
It covers **policy issuance, premium payments, claims submission, approval/rejection, and payouts** with full event logging and access control.

---

## 🚀 Features
- **Modular Design (Inheritance):** `AccessModule`, `PolicyModule`, `ClaimsModule`, `TreasuryModule` composed into **`InsuranceProject`**.
- **Standards:** OpenZeppelin `Ownable`, `Pausable`, `ReentrancyGuard`.
- **Transparent:** Rich events for explorers/analytics.
- **MVP by design:** ETH-based; easy to extend later (ERC20 premiums, KYC checks, Oracles).

---

## 📂 Repo Structure (suggested)
```
Course-End-Project-1-Insurance-SC/
│
├── contracts/
│   └── InsuranceProject.sol       # Main smart contract (renamed, fully commented)
│
├── README.md                      # This documentation
└── .gitignore                     # Ignore node_modules, env, artifacts
```

---

### Deployment Steps: Remix + MetaMask 
1. Go to <https://remix.ethereum.org>, create **`InsuranceProject.sol`**, paste the contract code from `contracts/InsuranceProject.sol`.
2. Compile with **Solidity 0.8.24** (or 0.8.20+).
3. Deploy (Injected Provider – MetaMask, Sepolia). Constructor param `initialInsurer`:
   - Use your wallet to operate daily actions, or pass `0x000...000` to default to the deployer.
4. Fund the contract: set **Value** (e.g., `0.1 ether`) and call `fund()`.
5. Flows:
   - `issuePolicy(holder, premiumWei, coverageWei, durationSeconds)` → returns `policyId` (see tx logs).
   - Holder pays: set Value=`premiumWei` and call `payPremium(policyId)`.
   - Holder submits: `submitClaim(policyId, amountWei, "reason")` → returns `claimId`.
   - Insurer: `approveClaim(claimId)` or `rejectClaim(claimId, "reason")`.
   - Insurer payout: `payClaim(claimId)`.
---

## 📝 Key Design Choices
- **Single deployable contract** keeps your MVP simple for demos & grading.
- **Insurer role** separated from `owner` so project owner can rotate operational admin safely.
- **CEI pattern** in `payClaim` + `ReentrancyGuard` to harden ETH transfers.
- **Pausable** circuit breaker for emergencies.
- **Event-heavy** for easy verification and analytics.

---

## 📌 Author
**Novendu Chakraborty**  
*Course-End Project 1 – Blockchain Smart Contracts*
