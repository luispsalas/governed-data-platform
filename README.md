# Governed Data Platform

**Access decided by classification, not by copies.** A working data platform where *who can
see what* is enforced by the platform itself rather than by convention, built on **Databricks Unity Catalog**, and tested by signing in as each kind of user to confirm they see only what
they should.

`Databricks` · `Unity Catalog` · `ABAC` · `data classification` · `column masking` · `row-level security` · `anonymization` · `data quality` · `lineage` · `SOC 2 mapping` · `synthetic data`

## At a glance

| | |
|---|---|
| **Goal** | Let analysts use real customer data from one copy, with the platform deciding who sees which rows and columns. |
| **What was done** | A Databricks Unity Catalog build on synthetic data (5,000 customers, 20,000 orders), every column labeled, every statement kept in `sql/`. |
| **Governance** | Rules keyed to those labels mask identifiers for all but data owners and limit an analyst to Europe's rows; a published table drops every identifier. |
| **Measurement** | Checked by signing in as each kind of user: the owner sees 4,940 rows, the analyst 1,684, masked. Ten `CHECK` constraints each refused a bad row. |

> **New here?** [GUIDE.md](GUIDE.md) is the shortest path to the useful parts: the design
> reasoning, the business decisions the platform cannot make for you, and the ten places this
> build's assumptions turned out to be wrong. This README describes *what* was built;
> the guide explains *why*, and what it cost to find out.

![Architecture: data flows from a landing volume through bronze and silver to a gold aggregate. Every column carries a classification tag, and one policy reads those tags so a data owner sees full values while an analyst sees masked values and only their own region's rows.](images/architecture.svg)

## The problem this solves

Most data platforms protect data at the edges: a warehouse is locked down, and everything
inside it is visible to everyone who gets in. That works until the first person asks a
reasonable question (*can the analytics team have access to the customer table?*), and the
honest answer is "yes, including the national ID numbers, because there is no way to give
them part of it."

The alternatives are usually worse. Copies get made with the sensitive columns stripped out,
and now there are two versions of the truth and nobody knows which one a report used. Or
access is granted with a promise not to look, which is not a control.

This project builds the other option: **one copy of the data, where the platform decides what
each person sees, row by row and column by column.** An analyst querying the customer table
gets real, useful data with the identifying values replaced. They are not looking at a
filtered copy; they are looking at the same table an engineer sees, through different rules.


## What is in here

| | |
|---|---|
| **[GUIDE.md](GUIDE.md)** | **Start here if you are about to build one of these.** What the work involves, which decisions belong to the business, and the places where a reasonable design meets the platform and loses |
| **[RUNBOOK.md](RUNBOOK.md)** | The full walkthrough: design, controls, and how each one was verified |
| [`SNOWFLAKE.md`](SNOWFLAKE.md) | Snowflake ↔ Databricks: governance differences that change a design, and the four ways the platforms actually connect |
| `sql/` | Every statement used to build it, in run order, commented for non-SQL readers, including the constraint and expectation scripts, which carry their own recorded results |
| `images/` | Lineage captured from the platform, showing the data flow and its classification |
| `generate_data.py` | Generates the synthetic dataset |

## How it works, in plain terms

Every column is labeled with what it is (a name, an email, a national ID, a birth date)
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
is not to hide the data; it is to keep it useful while it stops being identifying.**


## Keeping bad data out

Two different jobs, deliberately kept apart, because they fail differently:

| | What it does | When it acts |
|---|---|---|
| **`CHECK` constraints** | Refuse the write outright. Ten of them: non-negative amounts, known currency and status values, no future order dates, and the k-anonymity rule that keeps small groups out of the published aggregate | Before the row lands |
| **Pipeline expectations** | Let the write proceed and record what was wrong, or drop the row, or fail the run, one of three declared modes per rule | As the data moves |

Both are in `sql/`, with the rejection tests beside them: every constraint was proved by
sending it a row it had to refuse, and then **switched off to confirm the row got through**,
because a rule that fires is not yet a rule that was needed.

> **Coming from Snowflake?** Databricks *enforces* `CHECK` constraints; a violated one fails
> the transaction. Snowflake enforced only `NOT NULL` until April 2026 and now enforces `CHECK`
> too ([SNOWFLAKE.md](SNOWFLAKE.md)), so a habit formed on older Snowflake designs under-uses the
> strongest enforcement available here.


## Two ways to protect the same data

Masking and anonymization are often treated as the same move. They fail differently, and the
difference decides who can be given the data.

| | Masking | Anonymization |
|---|---|---|
| Where the protection lives | In a policy, applied when the column is read | In the shape of the data; the detail was never written |
| If the control is removed | The real values are served, silently | Nothing happens; there is nothing to reveal |
| If it breaks | Often invisible to the owner, who is exempt | The query fails loudly for everyone |
| Who can read the result | The roles the policy allows | Anyone |

Both are built here, on the same dataset:

**Structural, in the curated layer.** A full birth date was replaced by a birth *year*. The
mask that used to protect it returned the year anyway, so nobody lost information, and the
column that could be exposed by a policy change no longer exists. The mask and its policy
were then retired, because a control that guards nothing still reads as coverage.

**A published table, shareable by anyone.** A customer profile carrying no name, email,
phone, national ID, address, and **no customer key, not even a hashed one**. Ages become
decade bands, locations become regions, and any combination describing fewer than five
people is withheld, enforced by a constraint that was tested by trying to violate it.

> **A hashed ID is not anonymous.** Customer IDs here run `C00001`–`C05000`. Anyone who knows
> that format can hash every possible value in about a second and match them back. A hash
> without a secret is pseudonymization: useful, reversible, and a different promise. The
> published table therefore carries no key at all.

The return on removing those columns is concrete: the curated customer table is readable by
two roles, and the anonymized one is readable by everybody in the workspace.

**What anonymization does not do:** it answers *identification*, and nothing else. An analyst
restricted to European customers in the curated layer can read all-region totals here,
correct if the restriction meant "may not see their personal data", wrong if it meant "may
not know about them". No technical check can tell those apart; somebody has to write down
which one was meant.


## What this does NOT cover yet

Stated plainly, because a runbook that claims coverage it does not have is worse than a
short one.

- **Operating effectiveness.** Controls are mapped to SOC 2 criteria and the assertion suite
  re-runs on demand, but nobody runs it on a cadence, nobody reviews the audit log, and no
  change requires approval. That is control design, not evidence a control operated over
  a period. GDPR clauses are not mapped at all.
- **Account-level setup.** Metastore creation and identity federation are documented, not
  performed; a single workspace cannot demonstrate them.
- **Cross-platform policy, hands-on.** [`SNOWFLAKE.md`](SNOWFLAKE.md) sets out how these
  rules would be expressed in Snowflake, read from vendor documentation. They have not been
  built or tested on a second platform, and nothing views both through one catalog.


## What went wrong, and why that is the interesting part

Every control here was tested by signing in as each kind of user. That is what makes this a
record of a build rather than a description of a design, and it is where the findings came
from:

- Copying a table into the curated layer **silently dropped its sensitivity labels**, while
  keeping its written descriptions. The copy looked documented and was unprotected.
- A column type change turned a mask into a **query failure** for analysts, and the account
  that built it could not see the problem, because owners bypass their own masks.
- Six tables ended up owned by a person rather than a team, months of good intentions
  undone by the fact that **ownership does not apply to things created later**.
- Re-running a maintenance script that had already done its job **took away two teams'
  read access and left it that way**. It failed on the step that was already applied,
  after the step that removed access, before the one that gives it back. Nothing reported
  it, and the account that ran it could not have noticed: owners are exempt from the
  controls that broke.
- Adding a column placed it at the **end** of the table, while the obvious edit to the
  build script placed it in the **middle**. The next reload would have written birth years
  into a consent flag. Each file was correct on its own; only the pair was wrong, and
  nothing compares them.

> [!IMPORTANT]
> **None of these were found by the checks written to find them.** They surfaced some other
> way: one from a screenshot, one from a persona round looking for something else. The
> runbook says how, for each of them.
>
> That is the argument for testing governance as a second identity rather than reading
> the configuration: a control that is wrong and a control that is right look identical
> from the seat that built it.


## About the data

**Every person in this dataset is invented.** 5,000 customers and 20,000 orders generated
with [Faker](https://faker.readthedocs.io/), including deliberate defects: missing emails,
negative amounts, orders belonging to customers who do not exist, so that the data quality
rules have something real to catch.

The CSVs are not committed. `python generate_data.py` reproduces them exactly: the seed is
fixed, so the files are byte-identical every time.

Screenshots have been cropped and checked so they carry no account, workspace, or host
identifiers.
