# Your command-line agent team

Give your business a team of agents that read your real data and answer questions
from the command line. Add Buzz chat channels later if your team wants shared rooms.

Works with whatever you already have. If you use Claude Code, Codex, an OpenAI or
Anthropic key, or you run models locally with Ollama; it will find one and use it.
If you have none of those, pick any one and you are set.

---

## What you get

Five agents, each answering from your own numbers:

| Agent | What it watches |
|---|---|
| money | Revenue, invoices, what is owed |
| sales | Pipeline, quotes, deals in play |
| marketing | Ad spend, leads, what the money bought |
| ops | The board: what is open and stuck |
| systems | Servers and scheduled jobs |

Ask one a question and it answers from live data. They read and report; anything
that would change something waits for a person to approve it.

```
   your data                    your terminal
  ┌──────────┐                 ┌────────────────────┐
  │ CSV      │                 │ $ agent-engine.py  │
  │ command  │──▶ agents ────▶│   ask money "..." │◀── you
  │ URL      │                 └────────────────────┘
  └──────────┘
```

---

## Quick start: command line only

You need Python 3 and one supported model or model CLI. You do not need Rust,
Cargo, Buzz, or a chat service.

```bash
./bin/setup.sh
```

The setup finds a model, creates the local configuration, adds sample invoices,
and asks the money agent a real question. Buzz questions are optional: press
Return to skip them.

Ask another question yourself:

```bash
./bin/agent-engine.py ask money "what is overdue?"
```

### Privacy before you connect data

When you connect business data, the relevant contents leave your machine and go to
the third-party model provider the engine selected. Check that provider's privacy
terms and your company's data policy before connecting sensitive records such as a
P&L, customer list, or payroll export.

Then connect a CSV, command, URL, or published Google Sheet:

```bash
./bin/connect.sh
```

Run the setup check at any time:

```bash
./bin/agent-engine.py doctor
```

## Optional: add Buzz chat channels

The command-line agents work without Buzz. If you already have the Buzz CLI, set
`BUZZ_BIN` to its path and run `./bin/setup.sh` again to connect a workspace and
create channels.

If you want to build the optional Buzz CLI yourself:

```bash
git clone https://github.com/block/buzz && cd buzz
cargo build --release -p buzz-cli
```

> Building on an Apple Silicon Mac for a Linux server? The stock source will not
> cross-compile because one dependency pulls in a C library that fails under emulation.
> In the workspace `Cargo.toml`, change the `reqwest` feature from `"rustls"` to
> `"rustls-no-provider"` and it builds clean.

To prove the kit works end to end:

```bash
./bin/selftest.sh
```

Twenty-five checks, about a minute, touches nothing of yours.

---

## Connecting your own data

```bash
./bin/connect.sh
```

Pick an agent, pick where its data lives: a spreadsheet, an export, a web
address, a command, or a published Google Sheet. Then answer one question about
what is in it. No paths to format, no files to edit.

---

## Which brain gets used

The engine picks the first of these it finds, in this order:

1. `OPENAI_API_KEY`
2. `ANTHROPIC_API_KEY`
3. `OPENROUTER_API_KEY`
4. The Claude Code CLI, if it is installed
5. The Codex CLI, if it is installed
6. Ollama, if it is running locally

`./bin/agent-engine.py doctor` tells you which one it chose. If you want a
different one, set its key in `.env`; a key always wins over a CLI.

`AGENT_MODEL` only applies to the three API options. The CLIs use whatever model
they are already configured with.

---

## Pointing agents at your data

Open `agents.json`. Each agent has `sources`, which say where its facts come from. Three
kinds, mix as many as you like:

```json
{
  "sources": [
    "file:~/exports/invoices.csv",
    "shell:psql -c 'select * from orders'",
    "http:https:\u002f\u002fapi.example.com/v1/summary"
  ]
}
```

The first source reads a file you export or keep updated. The second runs a
command that prints data. The third reads data from a web address.

If a URL needs a password or token, do not hand-edit `.env`. Run `./bin/connect.sh`,
paste the token when it asks, and it stores that token against that one address only.
Each web source keeps its own credential, so one vendor's token is never sent to
another vendor's endpoint.

Give each source a plain-English label in `source_labels` so the agent knows what
it is looking at.

---

## Teaching an agent your rules

Numbers alone make agents recommend things you have already ruled out. Put the
rule in `agents.json` and it stops:

```json
{
  "rules": "- The starter product is a deliberate keep. Never recommend cutting it on cost-per-sale alone because it costs nothing to deliver.\n- Never state a target we have not set."
}
```

Rules override the numbers. This is the single highest-value thing you can add,
and it takes one line.

---

## Agents that remember

Rules in `agents.json` are permanent policy. Memory is for the hundred small things
you would otherwise repeat every week:

```bash
./bin/agent-engine.py remember money "Northline always pays late but always pays. Never chase before day 45."
```

Ask the same question again and the answer changes. Before that note the agent said
chase the biggest overdue invoice; after it, it says chase the second one and hold
the first for another 20 days.

Notes live in `memory/<agent>.md`, plain text you can open and edit. Agents read
them, never write to them, so nothing drifts behind your back.

```bash
./bin/agent-engine.py forget money      # wipe what it was told
```

This is the difference between an agent and a search box. Give each one five or six
notes in its first week and it starts sounding like someone who works there.

---

## Why the agents will not make things up

Every agent is given a fact sheet and told plainly: state nothing that is not in
it, and if a question needs something missing, say the data does not cover it.
The sheet ends with an explicit list of what is *not* available.

That last part matters most. An agent told only what it has will invent the rest;
an agent told what it does not have will say so.

---

## About the `pack/` folder

`pack/` holds the same five agents written in Buzz's own persona-pack format, and
`buzz pack validate ./pack` reports it valid.

**Be clear about what that means today:** nothing in Buzz loads a pack at runtime.
The format is real and carefully specified, but its only consumers are the `validate`
and `inspect` commands. Skills declared in a pack are never delivered, hooks are never
executed, and declared tool servers are never connected. The agents that actually run
in Buzz are created in the desktop app, and configured through environment variables.

So the pack is there for two reasons: it is the clearest written statement of what
each agent is and what rules it follows, and it becomes live the day Block wires the
loader. It is not how you install these agents today.

**The engine in `bin/` is what works.** That is what the rest of this document covers.

---

## Adding an agent

Copy a block in `agents.json`, change the name, channel, persona and sources, then:

```bash
./install.sh          # creates the new channel
./bin/agent-engine.py ask <name> "test question"
```

---

## Letting agents do things

By default agents read and talk. Two of them, ops and systems, can also
*propose* a job. Nothing runs on its own:

```bash
./bin/agent-engine.py pending      # what they have asked to do
./bin/agent-engine.py approve 1    # run it
./bin/agent-engine.py reject 1     # bin it
```

The agent writes the command, a person reads it and decides. Turn this on for any
agent by setting `"can_propose": true` in `agents.json`, or off by removing it.

---

## Commands

| Command | What it does |
|---|---|
| `doctor` | Checks the setup and names exactly what is missing |
| `list` | Shows your agents |
| `ask <name> "..."` | Asks on the command line, posts nothing |
| `brief <name>` | Posts that agent's update to its channel |
| `watch <name>` | Answers questions asked in its channel |
| `watch-all` | One pass over every agent |
| `remember <name> "..."` | Tell an agent something for good |
| `forget <name>` | Wipe what it was told |
| `pending` | Jobs waiting for your approval |
| `approve <n>` / `reject <n>` | Run one, or bin it |

---

## If something is not working

Run `./bin/agent-engine.py doctor` first; it names the exact missing piece.

The two most common:

- **"no brain found"**: set one key in `.env`, or install one of the CLIs.
- **"could not reach the relay"**: usually the agent identity has not been added
  as a member in the Buzz app yet.

Agents read and report. The two that can propose a job never run it. A person
approves each one, so nothing here can change your data on its own.

---

Made by Selr AI.
