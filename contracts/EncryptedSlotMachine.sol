// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * EncryptedSlotMachine
 *
 * FHEVM demo: privacy-preserving slot machine.
 *
 * Flow:
 * - User encrypts a random seed off-chain (Relayer SDK, externalEuint16 + proof).
 * - Contract interprets this seed directly as a "roll" in [0, ROLL_MODULUS),
 *   assuming frontend normalizes seed into that range.
 * - Contract computes a prize tier (0..3) fully under FHE:
 *      0 = no win
 *      1 = small win
 *      2 = big win
 *      3 = jackpot
 * - Contract stores encrypted seed/roll, prize tier and win flag.
 * - User decrypts their own result client-side via userDecrypt(...).
 *
 * Payout probabilities are controlled by three clear thresholds:
 *   jackpotLimit < bigWinLimit < smallWinLimit <= ROLL_MODULUS
 * Comparison is done on an encrypted "roll" in [0, ROLL_MODULUS).
 */

import {
  FHE,
  ebool,
  euint16,
  externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedSlotMachine is ZamaEthereumConfig {
  // -------- Ownership --------

  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;

    // Default payout curve (on roll in [0, ROLL_MODULUS)):
    //  - roll < 50    → tier 3 (jackpot)   ≈ 0.5%
    //  - roll < 250   → tier 2 (big win)  ≈ 2.5%
    //  - roll < 1000  → tier 1 (small win)≈ 10%
    //  - else         → tier 0 (no win)
    jackpotLimit = 50;
    bigWinLimit = 250;
    smallWinLimit = 1000;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // -------- Simple nonReentrant guard --------

  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // -------- Payout configuration (clear) --------

  uint16 public constant ROLL_MODULUS = 10000;

  /// @dev roll < smallWinLimit -> at least tier 1
  uint16 public smallWinLimit;
  /// @dev roll < bigWinLimit   -> at least tier 2 (bigWinLimit < smallWinLimit)
  uint16 public bigWinLimit;
  /// @dev roll < jackpotLimit  -> tier 3 (jackpotLimit < bigWinLimit)
  uint16 public jackpotLimit;

  event PayoutConfigUpdated(
    uint16 smallWinLimit,
    uint16 bigWinLimit,
    uint16 jackpotLimit
  );

  /**
   * Owner can tune payout distribution by changing clear thresholds.
   *
   * Invariant:
   *   0 < jackpotLimit < bigWinLimit < smallWinLimit <= ROLL_MODULUS
   */
  function setPayoutConfig(
    uint16 newSmallWinLimit,
    uint16 newBigWinLimit,
    uint16 newJackpotLimit
  ) external onlyOwner {
    require(newJackpotLimit > 0, "jackpot > 0");
    require(newJackpotLimit < newBigWinLimit, "jackpot < big");
    require(newBigWinLimit < newSmallWinLimit, "big < small");
    require(newSmallWinLimit <= ROLL_MODULUS, "small <= modulus");

    smallWinLimit = newSmallWinLimit;
    bigWinLimit = newBigWinLimit;
    jackpotLimit = newJackpotLimit;

    emit PayoutConfigUpdated(newSmallWinLimit, newBigWinLimit, newJackpotLimit);
  }

  // -------- Encrypted spin state --------

  struct SpinOutcome {
    euint16 eSeed;       // encrypted user seed (raw, also used as roll)
    euint16 eRoll;       // encrypted roll (same as eSeed, but kept separate for clarity)
    euint16 ePrizeTier;  // encrypted prize tier: 0..3
    ebool   eWin;        // encrypted win flag: (tier > 0)
    bool    decided;     // whether at least one spin exists
    uint64  lastSpinAt;  // timestamp of last spin
  }

  // player => last spin
  mapping(address => SpinOutcome) private spins;

  event SpinPlayed(
    address indexed player,
    bytes32 seedHandle,
    bytes32 rollHandle,
    bytes32 prizeTierHandle,
    bytes32 winFlagHandle
  );

  event PublicWinCertificateEnabled(
    address indexed player,
    bytes32 winFlagHandle
  );

  // -------- Core game logic --------

  /**
   * Spin the encrypted slot machine with a user-provided encrypted seed.
   *
   * Frontend flow (high-level):
   * 1) User picks a random seed (e.g. from browser RNG, 0..9999).
   * 2) Frontend normalizes seed into [0, ROLL_MODULUS) and encrypts it
   *    with Relayer SDK (createEncryptedInput).
   * 3) Gateway returns externalEuint16 + proof.
   * 4) Call spinEncrypted(...) with (encSeed, proof).
   * 5) Use getMyLastSpinHandles(...) + userDecrypt(...) to reveal result locally.
   */
  function spinEncrypted(
    externalEuint16 encSeed,
    bytes calldata proof
  ) external nonReentrant {
    require(proof.length != 0, "missing proof");
    // Require config to be in a valid range
    require(
      jackpotLimit > 0 &&
        jackpotLimit < bigWinLimit &&
        bigWinLimit < smallWinLimit &&
        smallWinLimit <= ROLL_MODULUS,
      "payout config not set"
    );

    SpinOutcome storage S = spins[msg.sender];

    // Ingest encrypted seed (already normalized on frontend)
    euint16 eSeed = FHE.fromExternal(encSeed, proof);

    // Authorize contract and user on the seed
    FHE.allowThis(eSeed);
    FHE.allow(eSeed, msg.sender);

    // Interpret seed directly as roll in [0, ROLL_MODULUS).
    // Frontend MUST ensure seed < ROLL_MODULUS before encrypting.
    euint16 eRoll = eSeed;

    // Prize tier computation (all under FHE):
    //
    // We define:
    //   roll < smallWinLimit   => at least tier 1
    //   roll < bigWinLimit     => at least tier 2
    //   roll < jackpotLimit    =>       tier 3 (jackpot)
    //
    // We implement this with chained FHE.select:
    //   ePrize = 0
    //   if roll < small  => ePrize = 1
    //   if roll < big    => ePrize = 2
    //   if roll < jackpot=> ePrize = 3
    //
    // Because jackpotLimit < bigWinLimit < smallWinLimit,
    // smaller ranges overwrite bigger ones.

    euint16 eZero = FHE.asEuint16(0);
    euint16 ePrize = eZero;

    ePrize = FHE.select(
      FHE.lt(eRoll, FHE.asEuint16(smallWinLimit)),
      FHE.asEuint16(1),
      ePrize
    );

    ePrize = FHE.select(
      FHE.lt(eRoll, FHE.asEuint16(bigWinLimit)),
      FHE.asEuint16(2),
      ePrize
    );

    ePrize = FHE.select(
      FHE.lt(eRoll, FHE.asEuint16(jackpotLimit)),
      FHE.asEuint16(3),
      ePrize
    );

    // Win flag: tier > 0 ?
    ebool eWin = FHE.gt(ePrize, eZero);

    // Persist encrypted outcome
    S.eSeed      = eSeed;
    S.eRoll      = eRoll;
    S.ePrizeTier = ePrize;
    S.eWin       = eWin;
    S.decided    = true;
    S.lastSpinAt = uint64(block.timestamp);

    // Ensure contract keeps rights on stored ciphertexts
    FHE.allowThis(S.eSeed);
    FHE.allowThis(S.eRoll);
    FHE.allowThis(S.ePrizeTier);
    FHE.allowThis(S.eWin);

    // Allow player to privately decrypt their result
    FHE.allow(S.eSeed, msg.sender);
    FHE.allow(S.eRoll, msg.sender);
    FHE.allow(S.ePrizeTier, msg.sender);
    FHE.allow(S.eWin, msg.sender);

    emit SpinPlayed(
      msg.sender,
      FHE.toBytes32(S.eSeed),
      FHE.toBytes32(S.eRoll),
      FHE.toBytes32(S.ePrizeTier),
      FHE.toBytes32(S.eWin)
    );
  }

  /**
   * Optional: player can turn their win flag into a public certificate.
   *
   * After calling this, anyone can call publicDecrypt on the win flag handle
   * (from getPlayerWinHandlePublic) to verify that this address had a winning spin.
   *
   * NOTE: irreversible from a privacy perspective (win/lose becomes public).
   */
  function enablePublicWinCertificate() external nonReentrant {
    SpinOutcome storage S = spins[msg.sender];
    require(S.decided, "no spin yet");

    // Make sure contract still has access
    FHE.allowThis(S.eWin);

    // Make win flag globally decryptable
    FHE.makePubliclyDecryptable(S.eWin);

    emit PublicWinCertificateEnabled(
      msg.sender,
      FHE.toBytes32(S.eWin)
    );
  }

  // -------- Getters (handles only, no FHE ops in view) --------

  /**
   * Returns encrypted handles for the caller's last spin:
   * - seedHandle:      encrypted seed (userDecrypt only)
   * - rollHandle:      encrypted normalized roll (userDecrypt only)
   * - prizeTierHandle: encrypted prize tier 0..3 (userDecrypt only)
   * - winFlagHandle:   encrypted boolean (userDecrypt; may also be public if
   *                    enablePublicWinCertificate was called)
   * - decided:         whether at least one spin was processed
   * - lastSpinAt:      timestamp of last spin (clear)
   */
  function getMyLastSpinHandles()
    external
    view
    returns (
      bytes32 seedHandle,
      bytes32 rollHandle,
      bytes32 prizeTierHandle,
      bytes32 winFlagHandle,
      bool decided,
      uint64 lastSpinAt
    )
  {
    SpinOutcome storage S = spins[msg.sender];
    return (
      FHE.toBytes32(S.eSeed),
      FHE.toBytes32(S.eRoll),
      FHE.toBytes32(S.ePrizeTier),
      FHE.toBytes32(S.eWin),
      S.decided,
      S.lastSpinAt
    );
  }

  /**
   * Public view on a player's win flag handle.
   *
   * - If the player has NOT enabled a public certificate, only they (via
   *   userDecrypt and ACL) will be able to decrypt this handle.
   * - If they DID enable a public certificate, anyone can publicDecrypt it.
   */
  function getPlayerWinHandlePublic(address player)
    external
    view
    returns (bytes32 winFlagHandle, bool decided, uint64 lastSpinAt)
  {
    SpinOutcome storage S = spins[player];
    return (
      FHE.toBytes32(S.eWin),
      S.decided,
      S.lastSpinAt
    );
  }
}
