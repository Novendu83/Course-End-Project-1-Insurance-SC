// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title InsuranceProject (OZ v4.9.6 pinned for Remix)
 * @notice Modular insurance MVP using OpenZeppelin v4:
 *         - Ownable (access control)
 *         - Pausable (circuit breaker)
 *         - ReentrancyGuard (payable safety)
 *
 * IMPORTANT for Remix:
 *   These imports are pinned to v4.9.6 to AVOID pulling OZ v5 (which changes Ownable constructor).
 *   Do NOT change the version in the import paths if you want OZ v4 behavior.
 */

import "@openzeppelin/contracts@4.9.6/access/Ownable.sol";
import "@openzeppelin/contracts@4.9.6/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@4.9.6/security/Pausable.sol";

/*//////////////////////////////////////////////////////////////
                             LIBRARY
//////////////////////////////////////////////////////////////*/
library InsuranceTypes {
    enum ClaimStatus { Pending, Approved, Rejected, Paid }

    struct Policy {
        address holder;      // owner of the policy
        uint256 premium;     // fixed premium per payment (wei)
        uint256 coverage;    // max claimable amount (wei)
        uint256 startAt;     // start timestamp (on issue)
        uint256 duration;    // seconds
        uint256 totalPaid;   // cumulative premiums paid
        bool active;         // becomes true after first premium
        bool cancelled;      // insurer can cancel
    }

    struct Claim {
        uint256 policyId;
        address claimant;    // policy holder
        uint256 amount;      // requested payout (<= coverage)
        string reason;       // short reason (full details off-chain)
        ClaimStatus status;
        bool exists;
    }
}

/*//////////////////////////////////////////////////////////////
                           SHARED STORAGE
//////////////////////////////////////////////////////////////*/
abstract contract InsuranceStorage {
    address public insurer;  // operational admin (distinct from owner)
    InsuranceTypes.Policy[] internal _policies;
    InsuranceTypes.Claim[]  internal _claims;
    mapping(uint256 => uint256[]) internal _policyClaims; // policyId => claimIds

    // Events
    event InsurerChanged(address indexed from, address indexed to);
    event PolicyIssued(uint256 indexed policyId, address indexed holder, uint256 premium, uint256 coverage, uint256 startAt, uint256 duration);
    event PremiumPaid(uint256 indexed policyId, address indexed payer, uint256 value, uint256 totalPaid);
    event PolicyCancelled(uint256 indexed policyId);
    event ClaimSubmitted(uint256 indexed claimId, uint256 indexed policyId, address indexed claimant, uint256 amount, string reason);
    event ClaimApproved(uint256 indexed claimId, uint256 indexed policyId, uint256 amount);
    event ClaimRejected(uint256 indexed claimId, uint256 indexed policyId, string reason);
    event ClaimPaid(uint256 indexed claimId, uint256 indexed policyId, address indexed to, uint256 amount);

    // Views
    function policiesCount() public view returns (uint256) { return _policies.length; }
    function claimsCount() public view returns (uint256) { return _claims.length; }
    function getPolicy(uint256 policyId) public view returns (InsuranceTypes.Policy memory) { return _policies[policyId]; }
    function getClaim(uint256 claimId) public view returns (InsuranceTypes.Claim memory) { return _claims[claimId]; }
    function getPolicyClaims(uint256 policyId) public view returns (uint256[] memory) { return _policyClaims[policyId]; }

    function _isExpired(uint256 policyId) internal view returns (bool) {
        InsuranceTypes.Policy memory p = _policies[policyId];
        if (p.startAt == 0) return false;
        return block.timestamp >= p.startAt + p.duration;
    }
}

/*//////////////////////////////////////////////////////////////
                        ACCESS / LIFECYCLE
//////////////////////////////////////////////////////////////*/
abstract contract AccessModule is InsuranceStorage, Ownable, Pausable {
    modifier onlyInsurer() {
        require(msg.sender == insurer, "Only insurer");
        _;
    }

    /**
     * @notice Owner sets/replaces the operational insurer.
     * @dev Common mistakes that revert here:
     *      - Calling from a non-owner account -> "Ownable: caller is not the owner"
     *      - Passing address(0) -> "Insurer=0"
     */
    function setInsurer(address newInsurer) public onlyOwner {
        require(newInsurer != address(0), "Insurer=0");
        emit InsurerChanged(insurer, newInsurer);
        insurer = newInsurer;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}

/*//////////////////////////////////////////////////////////////
                           POLICY MODULE
//////////////////////////////////////////////////////////////*/
abstract contract PolicyModule is InsuranceStorage, AccessModule, ReentrancyGuard {
    function issuePolicy(
        address holder,
        uint256 premiumWei,
        uint256 coverageWei,
        uint256 durationSeconds
    ) public onlyInsurer whenNotPaused returns (uint256 policyId) {
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

    function cancelPolicy(uint256 policyId) public onlyInsurer whenNotPaused {
        InsuranceTypes.Policy storage p = _policies[policyId];
        require(!p.cancelled, "Already cancelled");
        p.cancelled = true;
        emit PolicyCancelled(policyId);
    }
}

/*//////////////////////////////////////////////////////////////
                           CLAIMS MODULE
//////////////////////////////////////////////////////////////*/
abstract contract ClaimsModule is InsuranceStorage, AccessModule, ReentrancyGuard {
    function submitClaim(uint256 policyId, uint256 amountWei, string calldata reason)
        public whenNotPaused returns (uint256 claimId)
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

    function approveClaim(uint256 claimId) public onlyInsurer whenNotPaused {
        InsuranceTypes.Claim storage c = _claims[claimId];
        require(c.exists, "No claim");
        require(c.status == InsuranceTypes.ClaimStatus.Pending, "Not pending");
        c.status = InsuranceTypes.ClaimStatus.Approved;
        emit ClaimApproved(claimId, c.policyId, c.amount);
    }

    function rejectClaim(uint256 claimId, string calldata reason) public onlyInsurer whenNotPaused {
        InsuranceTypes.Claim storage c = _claims[claimId];
        require(c.exists, "No claim");
        require(c.status == InsuranceTypes.ClaimStatus.Pending, "Not pending");
        c.status = InsuranceTypes.ClaimStatus.Rejected;
        emit ClaimRejected(claimId, c.policyId, reason);
    }

    function payClaim(uint256 claimId) public onlyInsurer nonReentrant whenNotPaused {
        InsuranceTypes.Claim storage c = _claims[claimId];
        require(c.exists, "No claim");
        require(c.status == InsuranceTypes.ClaimStatus.Approved, "Not approved");

        InsuranceTypes.Policy storage p = _policies[c.policyId];
        require(address(this).balance >= c.amount, "Contract underfunded");

        c.status = InsuranceTypes.ClaimStatus.Paid;
        (bool ok, ) = payable(p.holder).call{value: c.amount}("");
        require(ok, "Payout failed");

        emit ClaimPaid(claimId, c.policyId, p.holder, c.amount);
    }
}

/*//////////////////////////////////////////////////////////////
                        TREASURY / FUNDING
//////////////////////////////////////////////////////////////*/
abstract contract TreasuryModule is InsuranceStorage, AccessModule, ReentrancyGuard {
    receive() external payable {}
    function fund() external payable onlyInsurer {}
    function withdraw(uint256 amount) external onlyInsurer nonReentrant {
        (bool ok, ) = payable(insurer).call{value: amount}("");
        require(ok, "Withdraw failed");
    }
}

/*//////////////////////////////////////////////////////////////
                           ROOT CONTRACT
//////////////////////////////////////////////////////////////*/
contract InsuranceProject is InsuranceStorage, AccessModule, PolicyModule, ClaimsModule, TreasuryModule {
    /**
     * @notice Constructor sets initial insurer (defaults to deployer).
     * @dev Ownable(v4) base constructor already sets owner = deployer.
     */
    constructor(address initialInsurer) {
        insurer = (initialInsurer == address(0)) ? msg.sender : initialInsurer;
        emit InsurerChanged(address(0), insurer);
    }

    function isExpired(uint256 policyId) external view returns (bool) {
        return _isExpired(policyId);
    }
}
