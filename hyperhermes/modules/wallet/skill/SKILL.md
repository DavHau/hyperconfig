---
name: lightning-wallet
description: Send and receive bitcoin over Lightning (invoices, Lightning addresses, offers, LNURL) or on-chain, check the balance and payment history. Use whenever a task involves paying for something, getting paid, or any sats/BTC amount.
---

# Shared Lightning wallet

You have full access to one Bitcoin/Lightning wallet (a phoenixd node on
this host). It is **shared by every agent here**: all agents spend from the
same balance, and everything you see in the history may be another agent's.
The float is small; treat it as real money.

Use the `lnwallet` command. Every subcommand prints JSON. Amounts are in
satoshis (1 BTC = 100,000,000 sat). `lnwallet <command> --help` lists the
options of a command.

## Look

- `lnwallet getbalance`: spendable `balanceSat` and `feeCreditSat`.
- `lnwallet getinfo`: node id and channels (no channel yet = nothing can be
  sent over Lightning).
- `lnwallet listoutgoingpayments --limit 20` /
  `lnwallet listincomingpayments --limit 20`: recent history, newest first.
- `lnwallet getoutgoingpayment --uuid <id>` or `--paymentHash <hash>`;
  `lnwallet getincomingpayment --paymentHash <hash>`.

## Pay

Decode before paying and check amount and description match what you
intend: `lnwallet decodeinvoice --invoice <lnbc...>`,
`lnwallet decodeoffer --offer <lno...>`.

- Invoice (`lnbc...`): `lnwallet payinvoice --invoice <lnbc...>`
  (add `--amountSat N` only for an invoice without an amount).
- Lightning address (`name@domain`, BIP353 or LNURL):
  `lnwallet paylnaddress --address name@domain --amountSat N [--message "..."]`
- Offer (`lno...`): `lnwallet payoffer --offer <lno...> --amountSat N`
- LNURL-pay: `lnwallet lnurlpay --lnurl <lnurl...> --amountSat N`
- On-chain address: `lnwallet sendtoaddress --address <bc1...> --amountSat N --feerateSatByte F`
  (costs a mining fee; prefer Lightning for small amounts).

A successful payment returns `recipientAmountSat`, `routingFeeSat` and a
`paymentPreimage`. A response with `"reason"` instead means the payment
failed; nothing was spent. Do not retry in a loop.

## Receive

- `lnwallet createinvoice --amountSat N --desc "what it is for"`: one-time
  invoice; share `serialized`. Check later with `getincomingpayment`.

When a payment does not fit the wallet's channel, receiving it costs a
liquidity fee taken from the payment: about 1,000 sat + 1% of the amount +
mining fee (`lnwallet estimateliquidityfees --amountSat N` shows it). Small
payments that cannot cover the fee are rejected. Never hand out an
on-chain address from `getswapinaddress`: deposits there are not credited
to the wallet. Never change the node's configuration.

## Rules

- Spend only when the task needs it, for the amount it needs. Say what you
  paid, to whom, and the fee (from the payment's response) in your reply.
- Never send the whole balance (`--sendAll`) unless your owner asked for it
  explicitly.
- Never close channels (`closechannel`): that costs on-chain fees and stops
  Lightning for every agent.
- Never print or store the wallet password or seed.
