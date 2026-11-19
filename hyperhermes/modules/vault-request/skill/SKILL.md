---
name: vault-request
description: "Use when a task needs a card, login or address the vault lacks. Send the user a one-time vault link, never ask in chat."
---

# Asking the user for a missing vault item

Your vault (`browser_vault`) fills saved cards, logins and addresses into
web pages without the values ever entering the conversation. When it lacks
what a task needs, ask the user to add it through `vault_request`: a
one-time link to a page behind their usual sign-in for your dashboard. It
works in every chat (Telegram, WhatsApp, the dashboard).

## When

- A checkout needs a card and `browser_vault action=list` has no `payment`
  item for that site (or the user wants a different card).
- A site needs a login you do not have, and `browser_vault
  action=save_login` is unavailable in this chat (it prompts only in the
  desktop app / TUI).
- A form needs a shipping or billing address and the vault has none.

Not for anything else: API keys, one-time codes (use `browser_vault
action=enter_code`), or values the user is happy to type into the site
themselves.

## How

1. `vault_request action=create kind=<payment|login|address> label="<short
   name>" origin=<https://site the item is filled on> reason="<one line why>"`.
   The origin is the exact site (scheme and host) where you will fill it;
   the vault fills it nowhere else.
2. Send the link with one sentence, for example:

   > To pay on shop.example.com I need a card in your vault. Please add it
   > here (sign in as usual; the link works once, for 30 minutes): <link>.
   > I never see the card details.

3. `vault_request action=wait request_id=<id>` (up to 600 s per call; call
   again while the state is `pending`). On `done` you get a `handle`.
4. `browser_vault action=fill handle=<handle>` on the checkout page (the
   user confirms every card fill). `expired`, `cancelled` or `error`: ask
   whether to send a new link.

## Never

- Ask for, accept, repeat or store a card number, CVC, password or address
  from chat. If the user pastes one, do not use it: say it is safer through
  the link and send one.
- Put values into the label or reason (the page shows them, and they are
  stored unencrypted).
- Send the link to anyone but the user you are working for. Only that
  agent's dashboard accounts can open it anyway.
