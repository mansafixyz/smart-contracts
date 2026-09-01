# MansaFi Protocol

The Solidity behind MansaFi, a confidential neobank for people and the AI agents working on their behalf. Everything here targets Robinhood Chain — an Arbitrum Nitro rollup — at chain ID 4663.

The codebase splits cleanly in two. `ConfidentialToken` is the primitive: a wrapper over USDG where balances and transfer amounts are ElGamal ciphertexts on the alt_bn128 curve, and an on-chain verifier confirms each transfer is sound without learning a single figure. Everything around it is the machinery that turns an encrypted balance into something you could call a bank account — durable `.mansafi` names, agents whose limits the chain itself enforces, a queue for spends a person ought to see first, request-to-pay links, and receipts proving a disclosure was made.

Both addresses in a transfer stay public from beginning to end. The figure between them does not.

## Why anything beyond the token

An encrypted balance buys confidentiality and nothing else. It cannot establish that `gwen.mansafi` is the person behind a wallet, that an agent has already burned through today's allowance, that a request link lapsed unpaid, or that its owner answered an auditor last March. None of that belongs inside the token, where every added constraint is another circuit to prove and another thing to get wrong. So it sits alongside as ordinary contract state, and the client composes the two at settlement.
