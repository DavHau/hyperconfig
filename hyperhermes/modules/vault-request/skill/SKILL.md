---
name: vault-request
description: "Use when a task needs a card, login or address the vault lacks, or the user asks where their stored logins are. One-time link; never in chat."
---

# Asking the user for a missing vault item

Your vault (`browser_vault`) fills saved cards, logins and addresses into
web pages without the values ever entering the conversation. When it lacks
what a task needs, ask the user to add it through `vault_request`: a
one-time link to a page behind their usual sign-in for your dashboard. It
works in every chat (Telegram, WhatsApp, the dashboard).

## How the vault binds items

- **Cards and addresses** fill on **any** website. Every single fill asks
  the user to confirm it, naming the page's site (and the payment
  processor's frame, and the total the page shows). One saved card serves
  every shop: never ask for the same card again because the site is new.
- **Logins** fill only on the exact site they were saved for (that is the
  phishing guard). A login for another site is a new login.

## When

- A checkout needs a card and `browser_vault action=list` has no `payment`
  item at all (or the user wants a different card).
- A site needs a login you do not have, and `browser_vault
  action=save_login` is unavailable in this chat (it prompts only in the
  desktop app / TUI).
- A form needs a shipping or billing address and the vault has none.

Not for anything else: API keys, one-time codes (use `browser_vault
action=enter_code`), or values the user is happy to type into the site
themselves.

## How

1. A card or address: `vault_request action=create kind=<payment|address>
   label="<short name>" reason="<one line why>"` (no origin).
   A login: `vault_request action=create kind=login label="<short name>"
   origin=<https://exact site> reason="<one line why>"`; the vault fills
   it on that site only.
2. Send the link with one sentence, for example:

   > To pay on shop.example.com I need a card in your vault. Please add it
   > here (sign in as usual; the link works once, for 30 minutes): <link>.
   > I never see the card details, and you confirm every payment.

3. `vault_request action=wait request_id=<id>` (up to 600 s per call; call
   again while the state is `pending`). On `done` you get a `handle`.
4. `browser_vault action=fill handle=<handle>` on the checkout page; the
   user confirms that fill. Declined: stop and ask them, do not retry. Not
   answered in time (`payment_unanswered`): tell the user, then call fill
   again once they are back; nothing was written.
   `expired` (unused): `vault_request action=renew request_id=<id>` makes
   the same link work for another 30 minutes, tell the user it works again.
   `cancelled` or `error`: ask whether to send a new link.

## Where the user sees what the vault holds

The user sees every item of your vault (label, kind, site, login name; a
card's brand and last 4 digits), shows and copies a login's password and
deletes items on their vault page, behind their usual sign-in. Get its
address from `vault_request action=where` and give exactly that address.
Tell the user about it when you
created a login with a generated password (`browser_vault create_login`)
and they may want to sign in themselves. If `where` returns no page, there
is none on this host: say so, do not invent one.

## Never

- Name a page, URL, menu or setting to the user that you have not seen
  exist: from a tool result (`vault_request where`, a link `create`
  returned) or by opening it yourself. If you are not sure where something
  is, say so.
- Ask for, accept, repeat or store a card number, CVC, password or address
  from chat. If the user pastes one, do not use it: say it is safer through
  the link and send one.
- Read, decrypt, copy or script around the vault's files or key, or type
  card values with JavaScript or the keyboard: `browser_vault fill` is the
  only way a value reaches a page.
- Put values into the label or reason (the page shows them, and they are
  stored unencrypted).
- Send the link to anyone but the user you are working for. Only that
  agent's dashboard accounts can open it anyway.
