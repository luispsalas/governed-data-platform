# Governed Data Platform

**Access decided by classification, not by copies.** A working data platform where *who can
see what* is enforced by the platform itself rather than by convention — built on Databricks
Unity Catalog, and tested by signing in as each kind of user to confirm they see only what
they should.

![Architecture: data flows from a landing volume through bronze and silver to a gold aggregate. Every column carries a classification tag, and one policy reads those tags so a data owner sees full values while an analyst sees masked values and only their own region's rows.](images/architecture.svg)

## The problem this solves

Most data platforms protect data at the edges: a warehouse is locked down, and everything
inside it is visible to everyone who gets in. That works until the first person asks a
reasonable question — *can the analytics team have access to the customer table?* — and the
honest answer is "yes, including the national ID numbers, because there is no way to give
them part of it."

The alternatives are usually worse. Copies get made with the sensitive columns stripped out,
and now there are two versions of the truth and nobody knows which one a report used. Or
access is granted with a promise not to look, which is not a control.

This project builds the other option: **one copy of the data, where the platform decides what
each person sees, row by row and column by column.** An analyst querying the customer table
gets real, useful data with the identifying values replaced. They are not looking at a
filtered copy — they are looking at the same table an engineer sees, through different rules.

## How it works, in plain terms

Every column is labeled with what it is — a name, an email, a national ID, a birth date —
and how sensitive it is. Those labels are the whole mechanism. A rule says *"wherever a
column is labeled as an email address, show only the first letter and the domain, to everyone
except the data owners."* The rule is written once and applies to every table that has such a
column, including tables that do not exist yet.

The result, for the same query on the same table:

| | Data owner sees | Analyst sees |
|---|---|---|
| `first_name` | `Rüdiger` | `***` |
| `email` | `rudiger.poelitz@example.de` | `r***@example.de` |
| `national_id` | `696-55-1549` | `e01159252fdfff4cb5f7c2f9...` |
| `date_of_birth` | `1951-05-18` | `1951-01-01` *(year only)* |
| rows returned | 4,940 (all regions) | 1,684 (Europe only) |

The email keeps its domain, so "which providers do our customers use" is still answerable.
The national ID becomes a consistent code, so records can still be counted and joined but
not traced to a person. The birth date keeps its year, so age analysis survives. **The goal
is not to hide the data — it is to keep it useful while it stops being identifying.**

## Keeping bad data out

Two different jobs, deliberately kept apart, because they fail differently:

| | What it does | When it acts |
|---|---|---|
| **`CHECK` constraints** | Refuse the write outright. Ten of them — non-negative amounts, known currency and status values, no future order dates, and the k-anonymity rule that keeps small groups out of the published aggregate | Before the row lands |
| **Pipeline expectations** | Let the write proceed and record what was wrong, or drop the row, or fail the run — one of three declared modes per rule | As the data moves |

Both are in `sql/`, with the rejection tests beside them: every constraint was proved by
sending it a row it had to refuse, and then **switched off to confirm the row got through** —
because a rule that fires is not yet a rule that was needed.

> **Coming from Snowflake?** Databricks *enforces* `CHECK` constraints; a violated one fails
> the transaction. Snowflake enforces only `NOT NULL` and treats the rest as informational.
> Carrying the Snowflake habit across under-uses the strongest enforcement available here.

## What is in here

| | |
|---|---|
| **[RUNBOOK.md](RUNBOOK.md)** | The full walkthrough: design, controls, and how each one was verified |
| `sql/` | Every statement used to build it, in run order, commented for non-SQL readers — including the constraint and expectation scripts, which carry their own recorded results |
| `images/` | Lineage captured from the platform, showing the data flow and its classification |
| `generate_data.py` | Generates the synthetic dataset |

## About the data

**Every person in this dataset is invented.** 5,000 customers and 20,000 orders generated
with [Faker](https://faker.readthedocs.io/), including deliberate defects — missing emails,
negative amounts, orders belonging to customers who do not exist — so that the data quality
rules have something real to catch.

The CSVs are not committed. `python generate_data.py` reproduces them exactly: the seed is
fixed, so the files are byte-identical every time.

Screenshots have been cropped and checked so they carry no account, workspace, or host
identifiers.

## What this does NOT cover yet

Stated plainly, because a runbook that claims coverage it does not have is worse than a
short one.

- **A full anonymization workflow.** What is here is masking — protection applied when data
  is read. Genuinely anonymized output, where the identifying values are never stored in the
  first place, is the next step.
- **Compliance control mapping.** The controls exist and are tested; they are not yet mapped
  to named SOC 2 or GDPR clauses.
- **Account-level setup.** Metastore creation and identity federation are described, not
  performed — a single workspace cannot demonstrate them.
- **Cross-platform policy.** The same rules expressed in a second platform, and the view
  across both, are not built.

## What went wrong, and why that is the interesting part

Every control here was tested by signing in as each kind of user. That is what makes this a
record of a build rather than a description of a design — and it is where the findings came
from:

- Granting metadata discovery to an auditor **did not let them read their own audit log**.
  Two permissions that sound alike do different jobs.
- Copying a table into the curated layer **silently dropped its sensitivity labels** — while
  keeping its written descriptions. The copy looked documented and was unprotected.
- A column type change turned a mask into a **query failure** for analysts, and the account
  that built it could not see the problem, because owners bypass their own masks.
- Six tables ended up owned by a person rather than a team, months of good intentions
  undone by the fact that **ownership does not apply to things created later**.

None of these were found by the checks written to find them. The runbook says how each one
surfaced.
