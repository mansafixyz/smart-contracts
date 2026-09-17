# MansaFi Protocol

The Solidity behind MansaFi, a confidential neobank for people and the AI agents working on their behalf. Everything here targets Robinhood Chain — an Arbitrum Nitro rollup — at chain ID 4663.

The codebase splits cleanly in two. `ConfidentialToken` is the primitive: a wrapper over USDG where balances and transfer amounts are ElGamal ciphertexts on the alt_bn128 curve, and an on-chain verifier confirms each transfer is sound without learning a single figure. Everything around it is the machinery that turns an encrypted balance into something you could call a bank account — durable `.mansafi` names, agents whose limits the chain itself enforces, a queue for spends a person ought to see first, request-to-pay links, and receipts proving a disclosure was made.

Both addresses in a transfer stay public from beginning to end. The figure between them does not.

## Why anything beyond the token

An encrypted balance buys confidentiality and nothing else. It cannot establish that `gwen.mansafi` is the person behind a wallet, that an agent has already burned through today's allowance, that a request link lapsed unpaid, or that its owner answered an auditor last March. None of that belongs inside the token, where every added constraint is another circuit to prove and another thing to get wrong. So it sits alongside as ordinary contract state, and the client composes the two at settlement.

## An agent, spending

An agent signs with `agentSigner`, a key held by whatever system operates it. That key is weak by design: it reaches only funds already sitting in a contract-controlled vault, only in the agent's single settlement token, and only within the policy its owner wrote. Nothing ever rests under the agent's own key, so a leak is answered by pausing or revoking rather than by racing the attacker to the exit.

A vault is an internal balance inside `AgentController`, credited by `fundAgent` against what actually arrived — a fee-on-transfer token cannot inflate the books. No agent can reach another's balance.

`hitlThreshold` decides which of two routes a spend takes:

- `payInvoice` settles then and there. It tests the per-transaction ceiling, the rolling 24-hour window, the recipient allowlist, and that the figure sits inside the threshold. The window advances by itself the first time a spend lands more than a day after it opened, so nothing ever has to call a reset.
- `queueInvoice` parks anything above the threshold and moves nothing. Allowlist and per-transaction ceiling are checked immediately, so the queue cannot be stuffed with spends that were never going to pass. The daily ceiling is deliberately left for approval time, because what fitted when it was queued may no longer fit when somebody actually looks.

The owner then calls `approvePending`, which re-runs the policy against its present state before releasing anything, or `rejectPending`, which drops the record. Since nothing was ever transferred, a rejection has nothing to undo.

Both routes carry an x402 `invoiceId` through to `AgentPaymentExecuted`, which is what an operator's webhook reconciles against.

Three controls sit over the top. `setAgentStatus` halts and restarts an agent without touching vault or policy. `rotateAgentSigner` installs a fresh key while preserving vault, policy, and history — the recovery path for a leaked key that stops short of demolition. `revokeAgent` is final, and returns whatever remains to the owner in the same transaction.

## A confidential transfer, mechanically

Every account registers an ElGamal public key and carries one ciphertext balance. Then:

- `deposit` wraps the underlying asset, folding `amount * G` into the message component with zero randomness. That is the standard Zether funding step, and it keeps the running balance readable to the depositor's own view key.
- `confidentialTransfer` takes two ElGamal deltas — one encrypting `-amount` to the sender, one encrypting `+amount` to the recipient — plus a proof. The verifier insists both carry the same non-negative figure and that the sender stays solvent. The contract then applies each delta by point addition, which is exactly why no figure ever appears in calldata or storage.
- `withdraw` unwraps against a proof that the encrypted balance covers it. The figure is public at this point, because the ERC-20 transfer that follows would expose it anyway.

The verifier lives behind `setVerifier` as a separate contract, so circuits can be upgraded without migrating a single balance. This layer also carries its own freeze, independent of the protocol-wide pause: it stops value moving while leaving registration and verifier rotation alive, which is what lets a suspect verifier be swapped out without stranding anyone.

## Fees, and what `$MANSA` does about them

One contract prices everything. `FeeSchedule.quoteFee(payer, amount)` returns the fee and the rate that produced it, and the app and SDK read the very same view to show someone their live rate beforehand.

```
grossFee  = amount * baseFeeBps / 10_000
discount  = discountBpsOf(payer)
netFee    = grossFee * (10_000 - discount) / 10_000
feeAmount = min(netFee, feeCap)
```

The discount follows a loyalty weight: `$MANSA` staked in `StakingVault` at full weight, `$MANSA` merely held at `heldWeightBps` of that (half, by default), with the total read against an ascending table. Staking beats holding, holding beats neither, and that ordering is the entire point — the more of the protocol you are tied to, the less it costs you to use.

Deployed defaults are a 0.10% base rate capped at 5 USDG, with thresholds at 1k, 10k, 100k, and 1M `$MANSA` earning 10%, 25%, 50%, and 75% off.

Fees ship switched off. Nothing charges anything until `ProtocolAuthority.setFeeConfig(treasury, feeSchedule)` names both, and clearing either one switches them off again everywhere. `AgentController` takes the fee from the agent's vault, discounted by the owner's holdings, and pointedly does not count it against the policy — those limits govern what the agent spends, not what the protocol charges to carry it. `RequestLedger` bills the payer on top of the amount so the recipient is left whole.
