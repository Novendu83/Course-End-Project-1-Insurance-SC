// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title InsuranceProject (Course-End Project 1)
 * @notice A clean, modular insurance system demonstrating best practices
 *         with OpenZeppelin (Ownable, Pausable, ReentrancyGuard).
 *         Core flows: policy issue, premium payment, claim submit/approve/reject/pay.
 *
 * @dev Design goals for academics/MVP:
 *      - Single deployable root contract (simple to demo & test)
 *      - Internal modularization via inheritance (easy to extend later)
 *      - Event-rich for transparency
 *      - ETH-based premiums/claims (can be swapped to ERC20 later)
 *
 *      Extensibility hooks:
 *      - Add Compliance/KYC checks in approveClaim (pre- or post-conditions)
 *      - Add Oracle module (parametric insurance) that auto-approves claims
 *      - Split Treasury to a separate contract if you want reusability across products
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/*//////////////////////////////////////////////////////////////////
                              LIBRARY
  Holds plain data structures for clarity and reuse across modules.
//////////////////////////////////////////////////////////////////*/
library InsuranceTypes {
    /// @dev Status of a claim through its lifecycle.
    enum ClaimStatus { Pending, Approved, Rejected, Paid }

    /// @dev Minimal policy model for an MVP.
    struct Policy {
        address holder;      // Wallet that owns/uses this policy
        uint256 premium;     // Fixed premium amount per payment (in wei)
        uint256 coverage;    // Maximum claimable amount (in wei)
        uint256 startAt;     // Policy start timestamp (set on issue)
        uint256 duration;    // Policy duration in seconds
        uint256 totalPaid;   // Sum of all premiums paid
        bool active;         // Becomes true after the first premium payment
        bool cancelled;      // Set true if the insurer cancels the policy
    }

    /// @dev Minimal claim model.
    struct Claim {
        uint256 policyId;    // Policy this claim belongs to
        address claimant;    // Policy holder (same as policy.holder)
        uint256 amount;      // Requested payout (≤ policy.coverage)
        string reason;       // Short reason/description (off-chain detail recommended)
        ClaimStatus status;  // Current claim status
        bool exists;         // Safety flag to distinguish missing IDs
    }
}

/*//////////////////////////////////////////////////////////////////
                            CORE STORAGE
  Centralizes state so modules share a single layout (upgrade-friendly).
//////////////////////////////////////////////////////////////////*/
abstract contract InsuranceStorage {
    /// @notice Operational admin for daily insurance actions
    /// @dev Distinct from Ownable.owner (project owner). Owner can replace insurer.
    address public insurer;

    // Arrays index serve as IDs: policyId = index in _policies, claimId = index in _claims
    InsuranceTypes.Policy[] internal _policies;
    InsuranceTypes.Claim[]  internal _claims;

    // policyId => list of claimIds for that policy
    mapping(uint256 => uint256[]) internal _policyClaims;

    /*----------------------------- Events -----------------------------*/
    event InsurerChanged(address indexed from, address indexed to);

    event PolicyIssued(
        uint256 indexed policyId,
        address indexed holder,
        uint256 premium,
        uint256 coverage,
        uint256 startAt,
        uint256 duration
    );
    event PremiumPaid(uint256 indexed policyId, address indexed payer, uint256 value, uint256 totalPaid);
    event PolicyCancelled(uint256 indexed policyId);

    event ClaimSubmitted(uint256 indexed claimId, uint256 indexed policyId, address indexed claimant, uint256 amount, string reason);
    event ClaimApproved(uint256 indexed claimId, uint256 indexed policyId, uint256 amount);
    event ClaimRejected(uint256 indexed claimId, uint256 indexed policyId, string reason);
    event ClaimPaid(uint256 indexed claimId, uint256 indexed policyId, address indexed to, uint256 amount);

    /*----------------------------- Views ------------------------------*/
    /// @notice Count of all policies
    function policiesCount() public view returns (uint256) { return _policies.length; }

    /// @notice Count of all claims
    function claimsCount() public view returns (uint256) { return _claims.length; }

    /// @notice Read a policy by id
    function getPolicy(uint256 policyId) public view returns (InsuranceTypes.Policy memory) {
        return _policies[policyId];
    }

    /// @notice Read a claim by id
    function getClaim(uint256 claimId) public view returns (InsuranceTypes.Claim memory) {
        return _claims[claimId];
    }

    /// @notice All claim ids under a policy
    function getPolicyClaims(uint256 policyId) public view returns (uint256[] memory) {
        return _policyClaims[policyId];
    }

    /// @dev Internal expiry check to reuse across modules
    function _isExpired(uint256 policyId) internal view returns (bool) {
        InsuranceTypes.Policy memory p = _policies[policyId];
        if (p.startAt == 0) return false; // not yet initialized
        return block.timestamp >= p.startAt + p.duration;
    }
}

/*//////////////////////////////////////////////////////////////////
                        ACCESS / LIFECYCLE MODULE
  - Ownable: project-level owner (course student/team)
  - insurer: operations role that performs daily insurance actions
  - Pausable: emergency stop on sensitive flows
//////////////////////////////////////////////////////////////////*/
abstract contract AccessModule is InsuranceStorage, Ownable, Pausable {
    /// @dev Restricts function to the insurer role (operational admin).
    modifier onlyInsurer() {
        require(msg.sender == insurer, "Only insurer");
        _;
    }

    /**
     * @notice Owner sets/replaces the operational insurer address.
     * @param newInsurer Address of the new insurer (must not be zero).
     */
    function setInsurer(address newInsurer) public onlyOwner {
        require(newInsurer != address(0), "Insurer=0");
        emit InsurerChanged(insurer, newInsurer);
        insurer = newInsurer;
    }

    /// @notice Pause all sensitive flows (owner only).
    function pause() external onlyOwner { _pause(); }

    /// @notice Unpause all sensitive flows (owner only).
    function unpause() external onlyOwner { _unpause(); }
}

/*//////////////////////////////////////////////////////////////////
                           POLICY MODULE
  Insurer issues/cancels; holder pays premiums.
//////////////////////////////////////////////////////////////////*/
abstract contract PolicyModule is InsuranceStorage, AccessModule, ReentrancyGuard {
    /**
     * @notice Insurer issues a new policy.
     * @param holder Wallet that will own/use this policy.
     * @param premiumWei Fixed premium amount per payment (in wei).
     * @param coverageWei Maximum claimable amount (in wei).
     * @param durationSeconds Policy duration in seconds.
     * @return policyId ID of the newly created policy.
     */
    function issuePolicy(
        address holder,
        uint256 premiumWei,
        uint256 coverageWei,
        uint256 durationSeconds
    ) public onlyInsurer whenNotPaused returns (uint256 policyId)
    {
        require(holder != address(0), "Holder=0");
        require(premiumWei > 0, "Premium=0");
        require(coverageWei > 0, "Coverage=0");
        require(durationSeconds > 0, "Duration=0");

        policyId = _policies.length;
        _policies.push(InsuranceTypes.Policy({
            holder: holder,
            premium: premiumWei,
            coverage: coverageWei,
            startAt: block.timestamp,
            duration: durationSeconds,
            totalPaid: 0,
            active: false,
            cancelled: false
        }));

        emit PolicyIssued(policyId, holder, premiumWei, coverageWei, block.timestamp, durationSeconds);
    }

    /**
     * @notice Policyholder pays one premium unit per call.
     * @dev Requires exact msg.value == policy.premium. Marks policy active on first payment.
     * @param policyId ID of the policy to pay for.
     */
    function payPremium(uint256 policyId) public payable nonReentrant whenNotPaused {
        InsuranceTypes.Policy storage p = _policies[policyId];
        require(!p.cancelled, "Policy cancelled");
        require(!_isExpired(policyId), "Policy expired");
        require(msg.sender == p.holder, "Only holder");
        require(msg.value == p.premium, "Incorrect premium");

        p.totalPaid += msg.value;
        if (!p.active) p.active = true;

        emit PremiumPaid(policyId, msg.sender, msg.value, p.totalPaid);
    }

    /**
     * @notice Insurer cancels a policy (e.g., fraud/eligibility).
     * @param policyId ID of the policy to cancel.
     */
    function cancelPolicy(uint256 policyId) public onlyInsurer whenNotPaused {
        InsuranceTypes.Policy storage p = _policies[policyId];
        require(!p.cancelled, "Already cancelled");
        p.cancelled = true;
        emit PolicyCancelled(policyId);
    }
}

/*//////////////////////////////////////////////////////////////////
                           CLAIMS MODULE
  Holder submits claims; insurer approves/rejects/pays.
//////////////////////////////////////////////////////////////////*/
abstract contract ClaimsModule is InsuranceStorage, AccessModule, ReentrancyGuard {
    /**
     * @notice Policyholder submits a claim.
     * @param policyId Policy ID under which the claim is made.
     * @param amountWei Requested payout in wei (must be > 0 and ≤ coverage).
     * @param reason Short human-readable reason (long detail should be off-chain/IPFS).
     * @return claimId New claim ID.
     */
    function submitClaim(uint256 policyId, uint256 amountWei, string calldata reason)
        public
        whenNotPaused
        returns (uint256 claimId)
    {
        InsuranceTypes.Policy storage p = _policies[policyId];
        require(!p.cancelled, "Policy cancelled");
        require(!_isExpired(policyId), "Policy expired");
        require(p.active, "Policy inactive");
        require(msg.sender == p.holder, "Only holder");
        require(amountWei > 0 && amountWei <= p.coverage, "Invalid amount");

        claimId = _claims.length;
        _claims.push(InsuranceTypes.Claim({
            policyId: policyId,
            claimant: msg.sender,
            amount: amountWei,
            reason: reason,
            status: InsuranceTypes.ClaimStatus.Pending,
            exists: true
        }));
        _policyClaims[policyId].push(claimId);

        emit ClaimSubmitted(claimId, policyId, msg.sender, amountWei, reason);
    }

    /**
     * @notice Insurer approves a pending claim.
     * @dev Insert KYC/compliance/oracle checks here if needed.
     * @param claimId Claim ID to approve.
     */
    function approveClaim(uint256 claimId) public onlyInsurer whenNotPaused {
        InsuranceTypes.Claim storage c = _claims[claimId];
        require(c.exists, "No claim");
        require(c.status == InsuranceTypes.ClaimStatus.Pending, "Not pending");
        c.status = InsuranceTypes.ClaimStatus.Approved;
        emit ClaimApproved(claimId, c.policyId, c.amount);
    }

    /**
     * @notice Insurer rejects a pending claim.
     * @param claimId Claim ID to reject.
     * @param reason Short reason for rejection (for event/auditing).
     */
    function rejectClaim(uint256 claimId, string calldata reason) public onlyInsurer whenNotPaused {
        InsuranceTypes.Claim storage c = _claims[claimId];
        require(c.exists, "No claim");
        require(c.status == InsuranceTypes.ClaimStatus.Pending, "Not pending");
        c.status = InsuranceTypes.ClaimStatus.Rejected;
        emit ClaimRejected(claimId, c.policyId, reason);
    }

    /**
     * @notice Insurer pays an approved claim to the policyholder.
     * @dev Follows CEI (Checks-Effects-Interactions). Requires pre-funded contract.
     * @param claimId Claim ID to pay.
     */
    function payClaim(uint256 claimId) public onlyInsurer nonReentrant whenNotPaused {
        InsuranceTypes.Claim storage c = _claims[claimId];
        require(c.exists, "No claim");
        require(c.status == InsuranceTypes.ClaimStatus.Approved, "Not approved");

        InsuranceTypes.Policy storage p = _policies[c.policyId];
        require(address(this).balance >= c.amount, "Contract underfunded");

        // Effects (update state before external call)
        c.status = InsuranceTypes.ClaimStatus.Paid;

        // Interaction (transfer ETH to policy holder)
        (bool ok, ) = payable(p.holder).call{value: c.amount}("");
        require(ok, "Payout failed");

        emit ClaimPaid(claimId, c.policyId, p.holder, c.amount);
    }
}

/*//////////////////////////////////////////////////////////////////
                         TREASURY / FUNDING MODULE
  Where claims are paid from. Keep simple for MVP (ETH-only).
//////////////////////////////////////////////////////////////////*/
abstract contract TreasuryModule is InsuranceStorage, AccessModule, ReentrancyGuard {
    /// @notice Accept direct ETH transfers (anyone can send)
    receive() external payable {}

    /// @notice Insurer can explicitly fund the pool via function call
    function fund() external payable onlyInsurer {}

    /// @notice Insurer can withdraw excess funds (e.g., after test/demo)
    function withdraw(uint256 amount) external onlyInsurer nonReentrant {
        (bool ok, ) = payable(insurer).call{value: amount}("");
        require(ok, "Withdraw failed");
    }
}

/*//////////////////////////////////////////////////////////////////
                           ROOT CONTRACT
  Deploy this single contract for the project MVP.
//////////////////////////////////////////////////////////////////*/
contract InsuranceProject is InsuranceStorage, AccessModule, PolicyModule, ClaimsModule, TreasuryModule {
    /**
     * @notice Constructor sets initial owner (deployer) and insurer (param or deployer).
     * @param initialInsurer Optional insurer address; if zero, defaults to deployer.
     */
    constructor(address initialInsurer) {
        // Set Ownable.owner = deployer (Ownable constructor is called automatically)
        _transferOwnership(msg.sender);

        // Set operational insurer
        insurer = (initialInsurer == address(0)) ? msg.sender : initialInsurer;
        emit InsurerChanged(address(0), insurer);
    }

    /// @notice Public view wrapper for expiry to keep ABI stable if you refactor internals.
    function isExpired(uint256 policyId) external view returns (bool) {
        return _isExpired(policyId);
    }
}
