// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MissionEscrow
 * @notice Escrow contract for Agent Marketplace missions with USDC payment,
 *         dependency DAG, and heartbeat timeout handling.
 * @dev UUPS upgradeable. All state transitions emit events.
 */
contract MissionEscrow is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    /// @notice USDC token interface
    IERC20 public usdc;

    /// @notice Registered agent addresses
    mapping(address => bool) public registeredAgents;

    /// @notice Mission states
    enum MissionState {
        NONE,
        CREATED,
        ASSIGNED,
        COMPLETED,
        TIMEOUT
    }

    /// @notice Mission data structure
    struct Mission {
        MissionState state;
        address creator;
        address agent;
        uint256 bounty;
        uint256 heldAmount;      // Amount in escrow
        uint256 releasedAmount; // Amount released to agent
        uint256 startBlock;
        uint256 expectedDurationMinutes;
        uint256 nonce;
        bytes32 rootHash;        // EAL root hash for verification
    }

    /// @notice Mission ID => Mission data
    mapping(bytes32 => Mission) public missions;

    /// @notice Mission ID => Dependency mission IDs
    mapping(bytes32 => bytes32[]) public missionDeps;

    /// @notice Timeout holds: missionId => amount held for dispute
    mapping(bytes32 => uint256) public timeoutHolds;

    /// @notice Dispute resolution timestamp for timeout holds
    mapping(bytes32 => uint256) public disputeEndTimes;

    /// @notice Global mission counter
    uint256 public missionCounter;

    /// @notice Discount basis points (5000 = 50%)
    uint256 public constant TIMEOUT_HOLD_BPS = 5000;
    /// @notice Dispute window duration (24 hours in seconds)
    uint256 public constant DISPUTE_WINDOW = 24 hours;

    // ============ Events ============

    /// @notice Emitted when an agent registers
    event AgentRegistered(address indexed agent);

    /// @notice Emitted when a mission is created
    event MissionCreated(
        bytes32 indexed missionId,
        address indexed creator,
        uint256 bounty,
        uint256 expectedDurationMinutes
    );

    /// @notice Emitted when a mission is assigned
    event MissionAssigned(
        bytes32 indexed missionId,
        address indexed agent,
        uint256 nonce
    );

    /// @notice Emitted when EAL is submitted and bounty released
    event MissionCompleted(
        bytes32 indexed missionId,
        bytes32 rootHash,
        uint256 amountReleased
    );

    /// @notice Emitted when mission times out
    event MissionTimeout(bytes32 indexed missionId);

    /// @notice Emitted when dependencies are set
    event DependenciesSet(bytes32 indexed missionId, bytes32[] dependencies);

    /// @notice Emitted when dispute hold is resolved
    event DisputeResolved(
        bytes32 indexed missionId,
        address recipient,
        uint256 amount
    );

    // ============ Initialization ============

    /**
     * @notice Initialize the escrow contract
     * @param _usdc USDC token address
     * @param _owner Contract owner address
     */
    function initialize(address _usdc, address _owner) public initializer {
        __Ownable_init(_owner);
        
        require(_usdc != address(0), "Invalid USDC address");
        usdc = IERC20(_usdc);
    }

    // ============ Agent Management ============

    /**
     * @notice Register a new agent
     * @param agent Address to register as agent
     */
    function registerAgent(address agent) external onlyOwner {
        require(agent != address(0), "Invalid agent address");
        registeredAgents[agent] = true;
        emit AgentRegistered(agent);
    }

    // ============ Mission Lifecycle ============

    /**
     * @notice Create a new mission and fund escrow
     * @param expectedDurationMinutes Expected completion time in minutes
     * @return missionId Unique mission identifier
     */
    function createMission(uint256 expectedDurationMinutes)
        external
        returns (bytes32 missionId)
    {
        missionId = keccak256(abi.encodePacked(++missionCounter, block.timestamp, msg.sender));

        Mission storage m = missions[missionId];
        m.state = MissionState.CREATED;
        m.creator = msg.sender;
        m.expectedDurationMinutes = expectedDurationMinutes;
        m.startBlock = block.number;
        m.heldAmount = 0;

        emit MissionCreated(missionId, msg.sender, m.bounty, expectedDurationMinutes);
    }

    /**
     * @notice Fund a mission (add USDC to escrow)
     * @param missionId Mission to fund
     * @param amount Amount of USDC to deposit
     */
    function fundMission(bytes32 missionId, uint256 amount) external {
        Mission storage m = missions[missionId];
        require(m.state == MissionState.CREATED, "Mission not in CREATED state");
        require(amount > 0, "Amount must be > 0");

        m.bounty += amount;
        m.heldAmount += amount;

        require(
            usdc.transferFrom(msg.sender, address(this), amount),
            "USDC transfer failed"
        );
    }

    /**
     * @notice Set dependencies for a mission (DAG)
     * @param missionId Mission to set dependencies for
     * @param deps Array of dependency mission IDs
     */
    function setDependencies(bytes32 missionId, bytes32[] calldata deps) external {
        Mission storage m = missions[missionId];
        require(m.creator == msg.sender, "Not mission creator");
        require(m.state == MissionState.CREATED, "Mission not in CREATED state");

        missionDeps[missionId] = deps;
        emit DependenciesSet(missionId, deps);
    }

    /**
     * @notice Check if all dependencies are resolved (COMPLETED)
     * @param missionId Mission to check dependencies for
     * @return true if all dependencies are COMPLETED
     */
    function checkDepsResolved(bytes32 missionId) public view returns (bool) {
        bytes32[] storage deps = missionDeps[missionId];
        for (uint256 i = 0; i < deps.length; i++) {
            if (missions[deps[i]].state != MissionState.COMPLETED) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Assign a mission to an agent
     * @param missionId Mission to assign
     * @param agent Address of the agent
     */
    function assignMission(bytes32 missionId, address agent) external {
        Mission storage m = missions[missionId];
        require(m.creator == msg.sender, "Not mission creator");
        require(m.state == MissionState.CREATED, "Mission not in CREATED state");
        require(registeredAgents[agent], "Agent not registered");
        require(m.bounty > 0, "Mission not funded");
        require(checkDepsResolved(missionId), "Dependencies not resolved");

        m.state = MissionState.ASSIGNED;
        m.agent = agent;
        m.nonce = uint256(keccak256(abi.encodePacked(missionId, block.timestamp, msg.sender)));

        emit MissionAssigned(missionId, agent, m.nonce);
    }

    /**
     * @notice Submit EAL and complete mission (releases USDC)
     * @param missionId Mission to complete
     * @param rootHash Root hash of the EAL execution
     * @param nonce Nonce from assignment (must match)
     */
    function submitEAL(bytes32 missionId, bytes32 rootHash, uint256 nonce) external {
        Mission storage m = missions[missionId];
        require(m.state == MissionState.ASSIGNED, "Mission not in ASSIGNED state");
        require(m.agent == msg.sender, "Not assigned agent");
        require(m.nonce == nonce, "Invalid nonce");
        require(m.nonce != 0, "Nonce already burned");

        // Burn nonce to prevent replay
        m.nonce = 0;
        m.rootHash = rootHash;
        m.state = MissionState.COMPLETED;

        // Release full bounty
        uint256 releaseAmount = m.heldAmount - m.releasedAmount;
        m.releasedAmount += releaseAmount;

        require(
            usdc.transfer(m.agent, releaseAmount),
            "USDC release failed"
        );

        emit MissionCompleted(missionId, rootHash, releaseAmount);
    }

    /**
     * @notice Trigger timeout (heartbeat missed)
     * @param missionId Mission that timed out
     */
    function triggerTimeout(bytes32 missionId) external {
        Mission storage m = missions[missionId];
        require(m.state == MissionState.ASSIGNED, "Mission not in ASSIGNED state");

        uint256 elapsedMinutes = (block.number - m.startBlock) * 12 / 60; // approx
        require(elapsedMinutes > m.expectedDurationMinutes, "Timeout not reached");

        m.state = MissionState.TIMEOUT;

        // Calculate hold amount (50%)
        uint256 holdAmount = (m.heldAmount * TIMEOUT_HOLD_BPS) / 10000;
        uint256 releaseAmount = m.heldAmount - holdAmount;

        timeoutHolds[missionId] = holdAmount;
        disputeEndTimes[missionId] = block.timestamp + DISPUTE_WINDOW;

        // Release partial amount immediately
        if (releaseAmount > 0) {
            m.releasedAmount += releaseAmount;
            require(
                usdc.transfer(m.agent, releaseAmount),
                "USDC release failed"
            );
        }

        emit MissionTimeout(missionId);
    }

    /**
     * @notice Resolve dispute after timeout (release held amount)
     * @param missionId Mission to resolve
     * @param to Recipient of held funds (agent or creator)
     */
    function resolveDispute(bytes32 missionId, address to) external onlyOwner {
        Mission storage m = missions[missionId];
        require(m.state == MissionState.TIMEOUT, "Mission not in TIMEOUT state");
        require(timeoutHolds[missionId] > 0, "No funds on hold");

        uint256 heldAmount = timeoutHolds[missionId];
        uint256 disputeEnd = disputeEndTimes[missionId];

        // Can only resolve after dispute window
        require(block.timestamp >= disputeEnd, "Dispute window ongoing");

        // Clear hold
        timeoutHolds[missionId] = 0;
        m.releasedAmount += heldAmount;

        require(
            usdc.transfer(to, heldAmount),
            "USDC transfer failed"
        );

        emit DisputeResolved(missionId, to, heldAmount);
    }

    // ============ UUPS ============

    /**
     * @notice Authorize upgrade
     * @param newImplementation New implementation address
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}
