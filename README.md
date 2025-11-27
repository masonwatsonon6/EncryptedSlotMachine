# Encrypted Slot Machine 🎰

**Encrypted Slot Machine** is a Zama FHEVM demo dApp that turns a classic slot machine into a fully private on-chain game.

The user sends an **encrypted random seed**, the contract evaluates the spin under **Fully Homomorphic Encryption (FHE)** and stores only:

* encrypted seed
* encrypted normalized roll
* encrypted prize tier `0..3`
* encrypted win flag

Only the player can decrypt the result via the **Relayer SDK `userDecrypt` flow**.
The contract never sees raw numbers — just ciphertexts and clear *payout thresholds*.

---

## Table of contents

* [Concept](#concept)
* [How winnings are calculated](#how-winnings-are-calculated)
* [Privacy & trust model](#privacy--trust-model)
* [User interface & flows](#user-interface--flows)

  * [1. Spin the encrypted reels](#1-spin-the-encrypted-reels)
  * [2. Decrypt your outcome](#2-decrypt-your-outcome)
  * [3. Admin · Payout curve](#3-admin--payout-curve)
* [Smart contract](#smart-contract)
* [Frontend](#frontend)
* [Project structure](#project-structure)
* [Local development](#local-development)
* [Deployment](#deployment)
* [Notes & limitations](#notes--limitations)
* [License](#license)

---

## Concept

Traditional on-chain games expose all internal state: seed, rolls, payout rules and outcomes are public in the mempool and on the chain.

**Encrypted Slot Machine** keeps the *entire spin* private:

* The **seed** comes from the user, encrypted client-side with the Relayer SDK.
* The **roll** and **prize tier** are computed directly on ciphertexts inside a Zama **FHEVM** contract.
* The **win/lose flag** and the prize tier are only decrypted **locally** in the browser – via a signed `userDecrypt` request.

The chain only sees:

* ciphertext handles (`bytes32`)
* clear payout thresholds (small win / big win / jackpot)

This makes it a good **educational example** of FHEVM for game mechanics.

---

## How winnings are calculated

The contract implements the following model:

* A fixed **roll modulus**:

  ```solidity
  uint16 public constant ROLL_MODULUS = 10000;
  ```

* Three clear threshold parameters (owner configurable):

  ```solidity
  uint16 public smallWinLimit;
  uint16 public bigWinLimit;
  uint16 public jackpotLimit;
  ```

  With the invariant:

  ```text
  0 < jackpotLimit < bigWinLimit < smallWinLimit <= ROLL_MODULUS
  ```

* The frontend generates a random `seed` in `[0, 9999]`, then encrypts it as `euint16`.

Inside the contract (`spinEncrypted`):

1. The encrypted seed is ingested:

   ```solidity
   euint16 eSeed = FHE.fromExternal(encSeed, proof);
   ```

2. The seed is treated as the **roll** (frontend normalizes it):

   ```solidity
   euint16 eRoll = eSeed;
   ```

3. The prize tier is computed **under FHE** using `FHE.select` and encrypted comparisons:

   ```solidity
   // Start with 0 (no win)
   euint16 eZero  = FHE.asEuint16(0);
   euint16 ePrize = eZero;

   // roll < smallWinLimit  → at least tier 1
   ePrize = FHE.select(
     FHE.lt(eRoll, FHE.asEuint16(smallWinLimit)),
     FHE.asEuint16(1),
     ePrize
   );

   // roll < bigWinLimit    → upgrade to tier 2
   ePrize = FHE.select(
     FHE.lt(eRoll, FHE.asEuint16(bigWinLimit)),
     FHE.asEuint16(2),
     ePrize
   );

   // roll < jackpotLimit   → upgrade to tier 3 (jackpot)
   ePrize = FHE.select(
     FHE.lt(eRoll, FHE.asEuint16(jackpotLimit)),
     FHE.asEuint16(3),
     ePrize
   );
   ```

4. The win flag is computed as `tier > 0` under FHE:

   ```solidity
   ebool eWin = FHE.gt(ePrize, eZero);
   ```

5. The contract stores:

   ```solidity
   struct SpinOutcome {
     euint16 eSeed;       // encrypted seed
     euint16 eRoll;       // encrypted roll (same as seed)
     euint16 ePrizeTier;  // encrypted tier 0..3
     ebool   eWin;        // encrypted win flag
     bool    decided;
     uint64  lastSpinAt;
   }
   ```

Prize tiers:

* `0` – no win
* `1` – small win
* `2` – big win
* `3` – jackpot

The *probabilities* are controlled by the three thresholds.
For example, with default settings:

```text
jackpotLimit = 50
bigWinLimit  = 250
smallWinLimit = 1000
ROLL_MODULUS = 10000

roll < 50      → tier 3 (≈ 0.5%)
roll < 250     → tier 2 (≈ 2.5%)
roll < 1000    → tier 1 (≈ 10%)
else           → tier 0
```

---

## Privacy & trust model

This dApp focuses on **privacy**, not on provably fair randomness:

* The **payout curve** (thresholds) is **public**.
* The **seed is chosen by the player**, not by the house.
* FHE ensures that **the contract never sees the clear seed, roll or prize tier**.
* Only the player can decrypt their own result via `userDecrypt`.

So it’s a good **FHEVM sandbox** and UX demo, not a production casino.

---

## User interface & flows

The UI is a single-page HTML app with a neon “slot machine” layout.

### 1. Spin the encrypted reels

Top block: **“1. Spin the encrypted reels”**

Elements:

* Neon header with machine name: `ZAMA · FHE SLOTS`.
* Three animated reels with emojis (`🍒`, `💎`, `7️⃣`, …).
* A status lamp showing:

  * `Waiting for your spin…`
  * `Spinning…`
  * `Win!` / `No win this time` (after decryption).

Buttons:

* **`SPIN WITH ENCRYPTED SEED`**

  * Generates a random `seed ∈ [0, 9999]` in the browser.
  * Encrypts it via Relayer SDK:

    ```js
    const buf = relayer.createEncryptedInput(CONTRACT_ADDRESS, account);
    buf.add16(seed);
    const { handles, inputProof } = await buf.encrypt();
    ```
  * Calls `spinEncrypted(handles[0], inputProof)` on the contract.
* **`REVEAL LAST RESULT (DECRYPT)`**

  * Re-reads the latest spin handles and runs `userDecrypt` again.

The note below explains that the contract only sees **encrypted seed / roll / tier / win flag**.

### 2. Decrypt your outcome

Middle block: **“2. Your encrypted outcome”**

Sections:

* **Prize tier**

  * Shows the decrypted tier (`0..3`) and a capsule legend:

    * `0 · no win`
    * `1 · small win`
    * `2 · big win`
    * `3 · jackpot`
* **Encrypted win flag**

  * Shows decrypted boolean (via `normalizeDecryptedValue(v) !== 0n`).
  * HTTPS badge:

    * `decrypt: HTTPS ✓` on secure origins
    * `decrypt: open via HTTPS` on insecure origins

Handles:

* **Last spin handles**

  * `seed: <bytes32>`
  * `roll: <bytes32>`
* **Prize / win handles**

  * `tier: <bytes32>`
  * `win flag: <bytes32>`

Under the hood, decryption uses:

```js
const { out, pairs } = await userDecryptMany(relayer, signer, [
  { handle: seedH, contractAddress: CONTRACT_ADDRESS },
  { handle: rollH, contractAddress: CONTRACT_ADDRESS },
  { handle: tierH, contractAddress: CONTRACT_ADDRESS },
  { handle: winH,  contractAddress: CONTRACT_ADDRESS },
]);

const pick = buildValuePicker(out, pairs);
const tier = pick(tierH);    // bigint
const win  = pick(winH);     // bigint (0/1)
```

The lamp + reels animation is updated based on the decrypted tier and win flag.

### 3. Admin · Payout curve

Bottom block: **“3. Admin · Payout curve”**

* Shows three numeric inputs:

  * **Small win limit** (`smallWinLimit`)
  * **Big win limit** (`bigWinLimit`)
  * **Jackpot limit** (`jackpotLimit`)
* Buttons:

  * `Refresh from contract`
  * `Update payout config` (owner-only)

The currently connected wallet’s role is shown in a badge:

* `role: owner` — can call `setPayoutConfig`.
* `role: viewer` — read-only.

The text explains how thresholds define the mapping from roll to prize tier.

---

## Smart contract

File: **`contracts/EncryptedSlotMachine.sol`**

Key points:

* Based on Zama’s FHEVM libraries:

  ```solidity
  import {
    FHE,
    ebool,
    euint16,
    externalEuint16
  } from "@fhevm/solidity/lib/FHE.sol";

  import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
  ```

* Avoids FHE operations in `view` functions – views only expose **handles** (`bytes32`), not clear values.

* Uses:

  * `FHE.fromExternal` for ingesting encrypted inputs.
  * `FHE.allowThis` / `FHE.allow` for access control.
  * `FHE.select`, `FHE.lt`, `FHE.gt` for encrypted comparisons.

* Optional path to make win flags publicly decryptable (if you enable it in the contract):

  * `getPlayerWinHandlePublic(address)` for public decryption with `publicDecrypt`.

---

## Frontend

File: **`frontend/encrypted-slot-machine.html`** (example name)

Technologies:

* **Ethers v6** from CDN.
* **Zama Relayer SDK** from CDN:
  `https://cdn.zama.org/relayer-sdk-js/0.3.0-5/relayer-sdk-js.js`
* Plain TypeScript-style JS in `<script type="module">`.
* No bundler required.

Relayer usage:

* `initSDK()` on load.
* `createInstance({ ...SepoliaConfig, relayerUrl, gatewayUrl, network })`.
* `createEncryptedInput(contract, user)` + `add16(seed)` + `encrypt()`.
* `userDecrypt(...)` with EIP-712 signature:

  * `generateKeypair()`
  * `relayer.createEIP712(...)`
  * `signer.signTypedData(...)`
* Careful handling of `BigInt`:

  ```js
  const safeStringify = (obj) =>
    JSON.stringify(obj, (k, v) => (typeof v === "bigint" ? v.toString() + "n" : v), 2);

  function normalizeDecryptedValue(v) {
    if (v == null) return null;
    if (typeof v === "boolean") return v ? 1n : 0n;
    if (typeof v === "bigint" || typeof v === "number") return BigInt(v);
    if (typeof v === "string") return BigInt(v);
    return BigInt(v.toString());
  }
  ```

Network:

* Ethereum **Sepolia** FHEVM testnet.
* Contract address:
  `0x7f2643BCE8e15Fad0178030aFB14485023E40e19`

---

## Project structure

Example layout:

```text
.
├── contracts/
│   └── EncryptedSlotMachine.sol      # FHEVM slot machine logic
├── deploy/
│   └── deploy.ts                     # Hardhat deploy script
├── frontend/
│   └── encrypted-slot-machine.html   # Single-page UI (this repo)
├── hardhat.config.ts                 # Hardhat + hardhat-deploy config
├── package.json
├── README.md
└── tsconfig.json (optional)
```

You can adapt the folder names to your own monorepo; the core pieces are:

* FHEVM contract
* Hardhat deployment
* Static HTML frontend

---

## Local development

1. **Install dependencies**

   ```bash
   npm install
   ```

2. **Compile contracts**

   ```bash
   npx hardhat compile
   ```

3. **Deploy to Sepolia FHEVM**

   Update your deploy script to use `EncryptedSlotMachine` and then:

   ```bash
   npx hardhat deploy --network sepolia
   ```

4. **Serve the frontend**

   Any static server works, for example:

   ```bash
   npx serve frontend
   ```

   For `userDecrypt` to work reliably, use **HTTPS** or `localhost` with a dev certificate.

5. **Open the UI**

   Navigate to `https://localhost:PORT/encrypted-slot-machine.html`
   Connect wallet → Spin → Decrypt.

---

## Deployment

On production:

* Host `encrypted-slot-machine.html` on an HTTPS domain.
* Point the frontend config to:

  * `relayerUrl = "https://relayer.testnet.zama.org"`
  * `gatewayUrl = "https://gateway.testnet.zama.org"`
* Ensure the contract address matches your latest deployment.

---

## Notes & limitations

* This is a **demo** – not a real-money gambling product.
* The slot machine is not “provably fair”:

  * The **player** chooses the seed.
  * The **payout curve** is public and can be simulated off-chain.
  * FHE is used to **hide the spin**, not to enforce randomness.
* Security considerations:

  * Always audit contracts before using real value.
  * Use HTTPS in production so that the Relayer workers run in a secure context.

---

## License

MIT
