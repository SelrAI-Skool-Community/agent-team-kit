# Business Team

Five agents for a small business. Each holds one part of it.

| Agent | Holds |
|---|---|
| Money | Invoices, cash, what is owed |
| Sales | Pipeline, quotes, deals |
| Marketing | Ad spend, leads, what the money bought |
| Ops | The board: what is open and stuck |
| Systems | Servers and scheduled jobs |

They read your data and answer in your channels. They never change a record, move
money, or contact a customer.

## Installing

Drop this folder into your Buzz workspace's plugin directory, or point the agent
engine at it. Check it first:

```bash
buzz pack validate ./pack
buzz pack inspect ./pack
```

## Making them yours

Each persona file ends with a **Standing rules** section. That is where the business
owner's decisions go: the things that should beat whatever the numbers suggest.
One line each. It is the highest-value edit in the whole pack.
