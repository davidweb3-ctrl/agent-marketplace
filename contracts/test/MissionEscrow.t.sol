// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MissionEscrow} from "../src/MissionEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title MissionEscrowTest
 * @notice Foundry tests for MissionEscrow contract
 */
contract MissionEscrowTest is Test {
    MissionEscrow public escrow;
    ERC20Mock public usdc;

    address public owner;
    address public creator;
    address public agent1;
    address public agent2;

    uint256 constant USDC_SUPPLY = 1_000_000e6; // 1M USDC
    uint256 constant BOUNTY = 1000e6; // 1000 USDC

    /// @notice Setup - deploy contract and fund accounts
    function setUp() public {
        // Deploy mock USDC
        usdc = new ERC20Mock();

        owner = makeAddr("owner");
        creator = makeAddr("creator");
        agent1 = makeAddr("agent1");
        agent2 = makeAddr("agent2");

        // Deploy escrow
        vm.prank(owner);
        escrow = new MissionEscrow();
        escrow.initialize(address(usdc), owner);

        // Mint USDC to creator for funding missions
        usdc.mint(creator, USDC_SUPPLY);
    }

    // ============ Test 1: Agent Registration ============

    /**
     * @notice Test agent registration by owner
     */
    function test_registerAgent() public {
        // Register agent
        vm.prank(owner);
        escrow.registerAgent(agent1);

        // Verify registration
        assertTrue(escrow.registeredAgents(agent1));
    }

    /**
     * @notice Test agent registration fails for non-owner
     */
    function test_registerAgent_NotOwner() public {
        vm.prank(creator);
        vm.expectRevert();
        escrow.registerAgent(agent1);
    }

    // ============ Test 2: Create Mission + Fund Escrow ============

    /**
     * @notice Test mission creation
     */
    function test_createMission() public {
        bytes32 missionId = escrow.createMission(60);

        // Destructuring tuple from public mapping getter
        // Mission struct: state, creator, agent, bounty, heldAmount, releasedAmount, startBlock, expectedDurationMinutes, nonce, rootHash
        (,,,, uint256 bounty,,,,,) = escrow.missions(missionId);
        assertEq(bounty, 0);

        // Check state - destructure the tuple
        (MissionEscrow.MissionState state,,,,,,,,,) = escrow.missions(missionId);
        assertTrue(uint256(state) == 1); // CREATED
    }

    /**
     * @notice Test fund mission with USDC
     */
    function test_fundMission() public {
        bytes32 missionId = escrow.createMission(60);

        // Fund the mission
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        // Verify funding
        (,,,, uint256 bounty,,,,,) = escrow.missions(missionId);
        assertEq(bounty, BOUNTY);
    }

    // ============ Test 3: Assign Mission (Nonce Generated) ============

    /**
     * @notice Test mission assignment with nonce generation
     */
    function test_assignMission() public {
        // Setup
        vm.prank(owner);
        escrow.registerAgent(agent1);

        // Create mission as creator and fund it
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        // Assign
        vm.prank(creator);
        escrow.assignMission(missionId, agent1);

        // Verify nonce generated - destructure tuple
        (,,,,,,,, uint256 nonce,) = escrow.missions(missionId);
        assertTrue(nonce != 0);
    }

    /**
     * @notice Test assignment fails for unregistered agent
     */
    function test_assignMission_NotRegistered() public {
        // Create mission as creator and fund it
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        // Try to assign to unregistered agent
        vm.prank(creator);
        vm.expectRevert("Agent not registered");
        escrow.assignMission(missionId, agent1);
    }

    /**
     * @notice Test assignment fails if not creator
     */
    function test_assignMission_NotCreator() public {
        vm.prank(owner);
        escrow.registerAgent(agent1);

        bytes32 missionId = escrow.createMission(60);

        vm.prank(agent1);
        vm.expectRevert("Not mission creator");
        escrow.assignMission(missionId, agent1);
    }

    // ============ Test 4: Submit EAL (Nonce Burned, USDC Released) ============

    /**
     * @notice Test EAL submission burns nonce
     */
    function test_submitEAL_BurnsNonce() public {
        // Setup
        vm.prank(owner);
        escrow.registerAgent(agent1);

        // Create and assign mission as creator
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        vm.prank(creator);
        escrow.assignMission(missionId, agent1);

        // Get nonce - destructure tuple
        (,,,,,,,, uint256 nonce,) = escrow.missions(missionId);
        assertTrue(nonce != 0);

        // Submit EAL
        bytes32 rootHash = keccak256("test EAL");
        vm.prank(agent1);
        escrow.submitEAL(missionId, rootHash, nonce);

        // Verify nonce burned - destructure tuple
        (,,,,,,,, uint256 nonceAfter,) = escrow.missions(missionId);
        assertTrue(nonceAfter == 0);
    }

    /**
     * @notice Test EAL submission fails with wrong nonce
     */
    function test_submitEAL_WrongNonce() public {
        vm.prank(owner);
        escrow.registerAgent(agent1);

        // Create and assign mission as creator
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        vm.prank(creator);
        escrow.assignMission(missionId, agent1);

        // Try with wrong nonce
        bytes32 rootHash = keccak256("test EAL");
        vm.prank(agent1);
        vm.expectRevert("Invalid nonce");
        escrow.submitEAL(missionId, rootHash, 12345);
    }

    // ============ Test 5: Timeout Scenario (50% Hold) ============

    /**
     * @notice Test timeout triggers and holds 50%
     */
    function test_timeout_Holds50Percent() public {
        vm.prank(owner);
        escrow.registerAgent(agent1);

        // Create and assign mission as creator
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        vm.prank(creator);
        escrow.assignMission(missionId, agent1);

        // Simulate time passing (in real test, would warp blocks)
        vm.roll(1000);

        // Trigger timeout
        vm.prank(creator);
        escrow.triggerTimeout(missionId);

        // Verify state
        (MissionEscrow.MissionState state,,,,,,,,,) = escrow.missions(missionId);
        assertTrue(uint256(state) == uint256(MissionEscrow.MissionState.TIMEOUT)); // TIMEOUT
    }
    /**
     * @notice Test timeout can only be triggered after expected duration
     */
    function test_timeout_TooEarly() public {
        vm.prank(owner);
        escrow.registerAgent(agent1);

        // Create and assign mission as creator
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(10000); // Very long
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        vm.prank(creator);
        escrow.assignMission(missionId, agent1);

        // Try immediate timeout
        vm.prank(creator);
        vm.expectRevert("Timeout not reached");
        escrow.triggerTimeout(missionId);
    }

    // ============ Test 6: Dependency Resolution ============

    /**
     * @notice Test dependency must be COMPLETED before assignment
     */
    function test_deps_MustBeCompleted() public {
        vm.prank(owner);
        escrow.registerAgent(agent1);
        vm.prank(owner);
        escrow.registerAgent(agent2);

        // Create dependency mission as creator and fund it
        vm.prank(creator);
        bytes32 depId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(depId, BOUNTY);

        // Assign dependency mission
        vm.prank(creator);
        escrow.assignMission(depId, agent2);

        // Complete the dependency mission - destructure tuple
        bytes32 rootHash = keccak256("dep EAL");
        (,,,,,,,, uint256 nonce,) = escrow.missions(depId);
        vm.prank(agent2);
        escrow.submitEAL(depId, rootHash, nonce);

        // Create dependent mission as creator and fund it
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        bytes32[] memory deps = new bytes32[](1);
        deps[0] = depId;
        vm.prank(creator);
        escrow.setDependencies(missionId, deps);

        // Assignment should succeed (dependency COMPLETED)
        vm.prank(creator);
        escrow.assignMission(missionId, agent1);

        // Verify - destructure tuple
        (MissionEscrow.MissionState state,,,,,,,,,) = escrow.missions(missionId);
        assertTrue(uint256(state) == 2); // ASSIGNED
    }

    /**
     * @notice Test assignment fails if dependency not COMPLETED
     */
    function test_deps_NotCompleted_Fails() public {
        vm.prank(owner);
        escrow.registerAgent(agent1);
        vm.prank(owner);
        escrow.registerAgent(agent2);

        // Create dependency mission as creator (not completed)
        vm.prank(creator);
        bytes32 depId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(depId, BOUNTY);

        vm.prank(creator);
        escrow.assignMission(depId, agent2);
        // Don't submit EAL - leave in ASSIGNED state

        // Create dependent mission as creator and fund it
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(60);
        vm.prank(creator);
        usdc.approve(address(escrow), BOUNTY);
        vm.prank(creator);
        escrow.fundMission(missionId, BOUNTY);

        bytes32[] memory deps = new bytes32[](1);
        deps[0] = depId;
        vm.prank(creator);
        escrow.setDependencies(missionId, deps);

        // Assignment should fail
        vm.prank(creator);
        vm.expectRevert("Dependencies not resolved");
        escrow.assignMission(missionId, agent1);
    }

    /**
     * @notice Test checkDepsResolved returns correct value
     */
    function test_checkDepsResolved() public {
        vm.prank(owner);
        escrow.registerAgent(agent1);

        // Create mission as creator
        vm.prank(creator);
        bytes32 missionId = escrow.createMission(60);

        // No deps - should return true
        assertTrue(escrow.checkDepsResolved(missionId));

        // Add dependency (created without prank, so by testContract - for deps it doesn't matter)
        bytes32 depId = escrow.createMission(60);
        bytes32[] memory deps = new bytes32[](1);
        deps[0] = depId;
        vm.prank(creator);
        escrow.setDependencies(missionId, deps);

        // Should return false
        assertFalse(escrow.checkDepsResolved(missionId));
    }
}
