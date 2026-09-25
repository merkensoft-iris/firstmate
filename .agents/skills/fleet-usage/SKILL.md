---
name: fleet-usage
description: >-
  Show LLM usage across the fleet with the signed-in account beside each host's usage windows when the captain invokes /fleet-usage or asks for the usage across the second mates, who is running low, or which Claude or Codex account each mate is on.
  It runs bin/fm-fleet-usage.sh once and relays the table with a two-line reading.
user-invocable: true
metadata:
  internal: true
---

# fleet-usage

One table, every host, the signed-in account beside the five-hour and weekly usage windows.
`bin/fm-fleet-usage.sh` owns every mechanic: which hosts are read, the one-connection-per-host transport, the columns, the sort, the attention section, and the `--toon` shape.
Read its header before changing what is relayed; nothing below restates it.

## What it does

1. Run `bin/fm-fleet-usage.sh` exactly once from this home.
   Do not read hosts by hand, do not re-run it per host, and do not retry an unreachable host inside the same turn; its row already says so.
2. Relay the table verbatim in the reply, then add a two-line reading in captain-facing language:
   - who is tight: the host, account, and provider with the least five-hour room, and any host whose weekly window is the real limit;
   - when it refills: the earliest five-hour reset and the weekly reset that matters, in the captain's local time as printed.
3. Relay the attention section as plain outcomes: a host that could not be read, a provider the laptop cannot measure until the captain approves the Keychain read once, or a sign-in that has lapsed.
   Ask for the captain's word only when one of those needs an action from them, such as approving that Keychain read or signing a mate back in.

## What it never does

- Invent or estimate a number the script printed as `-`.
- Print tokens, remedy commands, or any quota-axi section the script deliberately leaves out.
- Change a mate's sign-in, credentials, or provisioning; that is separate work under `secondmate-provisioning`.
