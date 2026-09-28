---
name: initiatives
description: >-
  Track named initiatives - groups of tasks across this home and every second mate - when the captain invokes /initiatives, asks to start or name an initiative or project tracker, asks to add tasks to one, asks for the status of ongoing initiatives, or asks to drill into one.
  Also load it when filing a task the captain said belongs to an initiative.
  It runs bin/fm-initiative.sh and relays the list or drill-down in captain language.
user-invocable: true
metadata:
  internal: true
---

# initiatives

An initiative is a named tracker whose status is gathered on demand from every home's backlog and done archive.
[`bin/fm-initiative.sh`](../../../bin/fm-initiative.sh) owns every mechanic: the commands, how members are found, the member states, and the three views.
[`docs/configuration.md`](../../../docs/configuration.md#initiative-trackers-datainitiatives) owns the record schema and the task tag.
Read those before changing what is relayed; nothing below restates them.

## What to do

- To start one, run `bin/fm-initiative.sh new <slug> --goal "<one line>"`, with `--name` and `--owner` when the captain gave them.
  Pick a short lowercase slug from the captain's own name for the initiative and say which slug you chose.
- To add tasks that already exist, run `bin/fm-initiative.sh add <slug> <task-id>...`, adding `--home <second-mate-id>` for tasks that live in a second mate's backlog.
- When filing a new task the captain placed in an initiative, add the tag line to its body at filing time; when the task is routed to a second mate, put the same line in the body that mate files.
- For "what is going on", run `bin/fm-initiative.sh list`; for one initiative, run `bin/fm-initiative.sh show <slug>`.
  Run the view once per request and do not re-read homes by hand.
- Only when the captain asks for a visual board, run `bin/fm-initiative.sh board [<slug>]` and give the page it opened; when it reports that Lavish is unavailable, relay the plain-text view it printed instead.

## How to relay

- Lead with each initiative's status and progress count, then name what needs the captain: tasks held for a decision first, then blocked tasks with the reason.
- Name tasks by their titles, keeping a task id only when the captain needs it to act.
- Copy every PR URL exactly as the view printed it.
- A home the view could not reach is part of the answer: say which second mate could not be reached and that its tasks may be missing or stale.
- Say the status was gathered just now and is not refreshed automatically yet.

## What it never does

- Edit a backlog, a task, or another home to make a view look complete.
- Treat a view as authority to dispatch, merge, or resolve anything it lists; each of those follows its own contract.
