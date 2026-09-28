# Governed Data Platform — Governance Runbook

## Contents
1. [What this is](#1-what-this-is)
2. [Architecture](#2-architecture)
3. [Classification taxonomy](#3-classification-taxonomy)
4. [Access control](#4-access-control)
5. [Masking and row-level security](#5-masking-and-row-level-security)
6. [Data quality controls](#6-data-quality-controls)
7. [How each control was verified](#7-how-each-control-was-verified)
8. [What is NOT built yet](#8-what-is-not-built-yet)

---

## 1. What this is

A record of building a governed data platform on Databricks Unity Catalog: the decisions, the
statements that implemented them, and — the part that matters — **how each control was
confirmed to actually work.**

Every claim here was tested by signing in as a second user and checking what they could
reach. That distinction runs through the whole document, because the single most common way
a governance design fails is that it was only ever reviewed, never exercised.

**Read it in order for the design, or jump to [section 7](#7-how-each-control-was-verified)
for the verification.** Each control names what was expected, what actually happened, and
what changed as a result.

### The design in one paragraph

Two catalogs separate production from development. Inside production, data moves through four
layers, getting cleaner and less identifying at each step. Every column carries labels saying
what it is and how sensitive it is. Access is granted to **groups**, never to people, and the
groups map to jobs: engineers build, analysts read curated data, auditors see what exists and
who touched it but never the data itself. Masking rules attach to the **labels**, not to
column names, so they apply automatically to tables that do not exist yet.

---

## 2. Architecture

### Two catalogs

| Catalog | Purpose |
|---|---|
| `prod_commerce` | Production. Nobody writes to it by hand; changes arrive through pipelines |
| `dev_commerce` | Development. Engineers have full rights to build and break things |

**Why two rather than one with stricter rules:** a boundary people can see is obeyed. "You may read production but only write in dev" is a sentence an engineer can act on without thinking about it; "be careful in production" is not.

### Four layers, plus one

| Schema | Holds | Who reads it |
|---|---|---|
| `landing` | Files exactly as received, in a volume | Engineers |
| `bronze` | Those files as tables, still untouched — every column stored as text | Engineers |
| `silver` | Typed, validated, one row per thing. Bad rows set aside with a reason | Engineers, analysts *(masked)* |
| `gold` | Business aggregates. No individuals, only groups | Engineers, analysts *(masked)* |
| `governance` | The masking rules themselves, and the audit log view | Nobody reads data here |

**Why bronze stores everything as text:** type inference is a silent data-loss mechanism. A
postcode of `01234` becomes the number `1234`, and nothing reports it. Bronze preserves
exactly what arrived; silver is where types are asserted deliberately. This was verified
rather than assumed — 409 postcodes and 447 national IDs with leading zeros survived
ingestion, matching the counts taken from the source files.

**Why `governance` is a separate schema:** policy logic is not business data. Keeping the
masking functions apart from the tables they protect means the people who can read customer
records are not the same people who can rewrite the rules governing them.

### Layer boundaries are where sensitivity drops

Landing, bronze and silver all hold directly identifying values and are classified
`restricted`. Gold holds only aggregates and is `internal`. That reduction — at the point
where data stops describing individuals — is the single most important boundary in the
design, and it is visible in the lineage captures in `images/`.

---

## 3. Classification taxonomy

Two labels, deliberately doing different jobs.

### `classification` — who may see it

| Value | Means | Example |
|---|---|---|
| `restricted` | Identifies a person on its own | name, email, national ID, street address, card number |
| `confidential` | Identifies a person **in combination** with others | city, postcode, date of birth, customer ID |
| `internal` | Everything else | region, segment, order date, amount, currency |

### `pii_type` — how it is protected

`name`, `email`, `phone`, `national_id`, `address`, `dob`, `dob_date`, `payment_card`

### Why two labels and not one

They answer different questions and change for different reasons. `classification` is a
**business judgment** about sensitivity — a compliance officer can review it without knowing
any SQL. `pii_type` is a **technical instruction** that selects a masking function. Merging
them would mean a stakeholder reviewing sensitivity had to also approve implementation
detail, and every new masking approach would force a change to the sensitivity scheme.

The distinction between `restricted` and `confidential` is the one worth arguing over. A
postcode identifies nobody. A postcode with a birth date and a gender identifies a great
many people. Labeling quasi-identifiers separately is what makes it possible to later ask
*"which columns, in combination, could re-identify someone?"* — the question an anonymization
review actually turns on.

### Everything is labeled, including the harmless

All 26 columns in bronze carry a `classification`, including the obviously non-sensitive
ones. **A missing label must mean "not yet classified," never "not sensitive."** If unlabeled
could mean either, the coverage check is worthless — and that check is the only thing standing
between a new column and an unprotected one.

### Labels are enforced, not conventional

`classification` and `pii_type` are **governed tags**: the allowed values are declared at
account level, and anything else is rejected. A typo of `restrcted` fails loudly instead of
creating a column that silently matches no rule.

*Practical note: allowed values are added one per entry. A comma-separated list creates a
single value containing commas, and every subsequent labeling statement fails with
`UC_TAG_POLICY_VALUE_NOT_ALLOWED` — an error that points at the label, not at the definition
that caused it.*

### Descriptions are a deliverable, not decoration

Every column carries a written description. Labels say how a column is handled; descriptions
say what it **means**, and the person approving access reads the second one. They state
format, meaning, and what a masked reader will see:

> **`national_id`** — Government identifier as issued, leading zeros preserved (stored as
> text for that reason). Analysts see a SHA-256 pseudonym, identical for the same person
> every time, so records can still be counted and joined but not resolved to a person.

> **`region`** — Sales region, lowercase: na, eu or latam. Governs row-level access — a
> member of `analyst_eu` sees only rows where this reads eu. Change it and you change who can
> see the customer, so it is owned by Sales Operations, not by the pipeline.

The second one records something no schema can: **changing this value changes who can see the
record**, so it belongs to the business, not to the pipeline.

---

## 4. Access control

### The personas, and the reasoning behind each

> **Engineers can read production but not change it.** They build freely in dev. In
> production, data should be changed only by pipelines running under a service identity, not
> by people. That is the dev/prod split built into the catalogs.
>
> **Analysts never see the raw layers.** Landing and bronze hold unmasked identifying data.
> Analysts start at silver, where it is masked.
>
> **Auditors check the controls, not the data.** Metadata discovery shows them what exists,
> its labels and its descriptions, but no rows. The audit log shows them who accessed what.
>
> **Ownership goes to a group**, per Databricks guidance for production.

### The matrix

| Group | `prod_commerce` | `dev_commerce` | Compute |
|---|---|---|---|
| `commerce_data_owners` | **Owns** catalog, schemas, tables, volume | Owns catalog | — |
| `data_engineer` | `USE CATALOG`; `SELECT` on bronze/silver/gold; `READ VOLUME` on landing; **no `MODIFY`** | `ALL PRIVILEGES` | Can manage |
| `analyst` | `USE CATALOG`; `USE SCHEMA` + `SELECT` on silver and gold only | — | Can use |
| `analyst_eu` | *Grants nothing.* Narrows an analyst to EU rows | — | — |
| `auditor` | `BROWSE` + `USE CATALOG`; `SELECT` on the audit log view only | — | Can use |

`analyst_eu` is worth a note: a group that grants **no access at all** and exists only to
narrow it. Membership of it alone gives nothing; combined with `analyst` it restricts rows to
Europe. Access and scope are separate decisions, so they are separate groups.

*Databricks groups have no description field, which means the group name must carry its own
meaning and this runbook is the registry for what each one is for.*

### Platform defaults — the half of the matrix most documents omit

Effective access is **what you granted plus what the platform gave away**. These were present
before any grant was written:

| Default | Decision |
|---|---|
| `account users` → `BROWSE` on every new catalog | **Revoked on production.** Column names, labels and descriptions describe where the sensitive data lives. Kept on dev, where discoverability helps and the risk is low |
| `All workspace users` → `Can use` on the SQL warehouse | **Removed.** Otherwise everyone has compute regardless of the data matrix |
| A `default` schema, auto-created in every catalog | **Dropped.** An unclassified schema nobody designed is where ungoverned tables appear |

A matrix listing only deliberate grants is wrong by omission. Auditing what the platform
grants by default is a distinct task from deciding what to grant, and it is easy to skip
because nothing prompts you to do it.

### Compute is a separate gate

Data access and the ability to run a query are governed independently. A user removed from
every group could not run SQL **at all** — the failure was about warehouses, not about
tables:

> *No SQL Warehouse available — You do not have an available SQL Warehouse to which this
> query can be attached.*

Useful to know in both directions: a persona can be correctly denied at either gate, and a
denial that mentions compute says nothing about whether the data matrix is right.

### Ownership does not apply forward in time

Ownership is transferred **per object**. Transferring a catalog, its schemas and its existing
tables to a group does not cover tables created afterwards — those belong to whoever created
them.

This was not caught by reasoning about it. Six tables built in a later phase were all
personally owned, quietly reintroducing the single-person dependency the group-ownership
decision existed to remove, and it surfaced on a **lineage screenshot** — because no query in
the verification suite had ever asked who owns anything.

The standing check now runs after any phase that creates objects:

```sql
SELECT table_schema, table_name, table_owner
FROM prod_commerce.information_schema.tables
WHERE table_schema IN ('bronze','silver','gold','governance')
  AND table_owner <> 'commerce_data_owners';
```

**Its expected result is one named exception, not zero.** The audit log view must stay owned
by an identity that can read the system tables, which the owning group cannot. A check
written to expect zero would flag it forever — and the obvious way to silence that warning is
to transfer it, which breaks the audit view. Where a control has a legitimate exception,
write the exception into the expected result; a check that cries wolf teaches people to make
the harmful fix.

### Two practical cautions

**Add yourself to the owning group before transferring ownership.** Otherwise the transfer
removes your own rights over the catalog.

**Group membership is not instant, and it does not arrive everywhere at once.** After adding
a user to a group, the warehouse permission was live — queries ran — while the membership
function still reported `false`. Acting on that gap produces a denial that looks correct and
only means the change had not landed. Gate every test on a **positive control**: something
only that persona can do. A denial on its own proves nothing.

---

## 5. Masking and row-level security

### Rules attach to labels, not to columns

A masking rule could name the column it protects. These name a **label**:

> Wherever a column is labeled `pii_type = email`, show only the first letter and the domain
> — to everyone except the data owners.

Written once, it covers every such column in the catalog, **including in tables that do not
exist yet**. One rule per kind of sensitive data instead of one per column, and a new table
arrives protected the moment its columns are labeled.

The cost is real and worth stating: protection now depends entirely on labeling being correct
and present. **A rule can only protect what is labeled**, which turns the unlabeled-column
check from a one-time task into a permanent control.

### What each mask preserves

Masking is not deletion. Each choice keeps something analytically useful:

| Kind of data | What an analyst sees | What survives |
|---|---|---|
| name, address, phone | `***` | Nothing — there is no analysis these serve |
| email | `r***@example.de` | The domain, so provider mix stays answerable |
| payment card | `****4321` | The last four, enough to match a support enquiry |
| national ID | 64-character hash | Consistency — the same person hashes the same every time, so records still count and join |
| date of birth | year only | Age analysis, while the exact date stops being a re-identification key |

The national ID mask is **deterministic pseudonymization**, and takes a version argument so
keys can be rotated without rewriting history. Worth being precise about what that is: under
GDPR, pseudonymized data is **still personal data**, because the mapping exists. It reduces
exposure; it does not remove the record from scope.

### Somebody must be able to see the real data

The rules exempt one group: `commerce_data_owners`. Exempting nobody sounds stronger and is
worse — someone has to validate raw data, and if the platform forbids it, that work moves to
an export nobody governs. **Naming the exception inside the rule makes it auditable.**

That same exemption has a consequence worth internalizing: an owner testing the masks sees
nothing wrong, ever. See [section 7](#7-how-each-control-was-verified).

### Row-level security

One rule restricts a group to its own region, matching on a label that marks the
region-bearing column:

> Members of `analyst_eu` see only rows where the region column reads `eu`.

Tag-driven rather than per-table, for the same reason as the masks: it covers tables created
later. It was attached at **catalog level**, so the curated and aggregate layers inherited it
as they were built.

### The aggregate layer needs a different control

Gold contains no individuals, so there is nothing to mask. The protection becomes **group
size**: an aggregate over four people describes those four people. Groups with fewer than
five distinct customers are not published.

Measured cost: **32 of 336 groups withheld — 9.5% of the groups, 0.5% of the value.** That
pair of numbers is what to put in front of whoever approves the threshold. The control bites,
and it is nearly free.

One consequence a reader cannot infer: **an absent combination means suppressed, not empty.**
That is stated in the column description, because nothing else would tell them.

### Limits worth knowing before designing around this

- **Only one mask may resolve per column, per user.** Two matching rules block access rather
  than picking one, so rules must match mutually exclusive labels.
- **Time travel and cloning fail** on tables carrying these rules.
- **Masks bind to the column TYPE; labels describe MEANING.** These disagree the moment a
  layer changes types — which is exactly what a curated layer is for. A mask written for a
  text column and applied to a date column does not mask it; it makes the column unreadable.

That last one is the sharpest finding in this project, and it is covered next.

---

## 6. Data quality controls

Two mechanisms, kept separate because they fail differently and are read by different people.

### Constraints — refuse the write

Ten `CHECK` constraints on the silver and gold tables. A violated one fails the transaction,
so the bad row never lands:

| Rule | Guards against |
|---|---|
| Non-negative amounts | Sign errors arriving from the source |
| Known `status`, `currency`, `region` values | A vocabulary drifting without anyone deciding |
| No future order dates | Back-dated or clock-skewed rows inflating a forecast |
| Group size at least 5 | A published aggregate describing a handful of identifiable people |

The last one is worth naming: **k-anonymity enforced as a constraint rather than as a
convention.** The suppression rule is applied when the aggregate is built, and the constraint
then makes it impossible to publish a row that breaks it — two independent statements of the
same rule, so a mistake in one is caught by the other.

> **Coming from Snowflake?** Databricks *enforces* `CHECK` constraints — *"when a constraint
> is violated, the transaction fails with an error."* Snowflake enforces only `NOT NULL` and
> treats the rest as informational. Primary and foreign keys are informational in **both**.
> A habit carried across from Snowflake under-uses the strongest enforcement available here.

### Expectations — let it through, but on the record

Declared pipeline expectations, each with one of three modes: keep the row and count the
violation, drop the row, or fail the run. All three are demonstrated in `sql/`.

The distinction that matters when choosing between them: a constraint answers *"must this
never happen?"*, an expectation answers *"what should we do when it does?"* Most real rules
are the second kind, and forcing them into the first produces a pipeline that stops overnight
for a row nobody would have cared about.

### Where the allowed values came from, and why that matters

The value lists in these constraints were read out of the data — `SELECT status, COUNT(*) …
GROUP BY status` — rather than assumed. That makes them a demonstration of the mechanism,
**not a governed vocabulary.** On the first attempt the values *were* assumed, four of five
were invented, and the revenue rule built on them matched zero rows.

In a real engagement each list is a **business sign-off**: versioned, with a named owner, and
changing it is a change-controlled event — because a constraint turns a vocabulary into
something that can reject production writes. Deriving an enforced rule from a sample is how
yesterday's data quietly becomes tomorrow's policy.

### How these were verified

Every constraint was sent a row it had to refuse; all eight rejection tests were refused, each
naming the constraint that stopped it. Then the step that usually gets skipped: **the rule was
switched off and the same row sent again, to confirm it then got through.** A rule that fires
is not yet a rule that was needed — something else may already have been catching it.

One property worth recording, because it contrasts sharply with the masking controls: a
rejected write **names the constraint that rejected it.** A failing column mask does not name
the mask — it surfaces as a cast error several layers from its cause. Same platform, two
governance mechanisms, opposite diagnosability.

---

## 7. How each control was verified

### The principle

**An owner-run check proves nothing about access control.** The owner is exempt from every
mask and bypasses the matrix, so every query succeeds regardless of whether the controls
work. Verification means signing in as a **second, separate identity**, one persona at a
time, and looking at what it can actually reach.

Each round is gated on a **positive control** — something only that persona can do — because
a denial is ambiguous. It looks identical whether the persona is correctly denied or the
group membership has not propagated yet.

### What each persona sees

Confirmed with a second account, one persona at a time:

| | Owner | Analyst (`analyst` + `analyst_eu`) | Auditor | No group |
|---|---|---|---|---|
| Schemas visible | all five | `silver`, `gold` | all five *(metadata only)* | none |
| `silver.customers` | 4,940 rows, real values | **1,684 rows, masked, Europe only** | denied | — |
| `gold` aggregates | 304 groups | **54 groups, Europe only** | denied | — |
| `bronze` (raw) | readable | **denied at `USE SCHEMA`** | denied | — |
| Audit log | readable | denied | **1,344 events** | — |
| Run any query | yes | yes | yes | **no compute at all** |

The analyst denial on raw data lands at `USE SCHEMA`, one level **above** the table — raw
data is unreachable before table permissions are even consulted.

### Findings, and how each surfaced

Every one was found by a check other than the one written for it.

**Metadata discovery is not query traversal.** The auditor was granted `BROWSE`, which sounds
like read-only access. They could not query anything — including the audit log view built for
them. `BROWSE` covers discovery in the interface; running a query needs `USE CATALOG`.
Granting it kept least privilege intact: traversal alone exposes no data. *Found by testing
as the auditor; invisible to review.*

**Copying a table drops its labels but keeps its descriptions.** Creating a curated table
from a labeled source produced a table with **zero** labels — so none of the masking rules
matched it, and it held real identifying data with nothing errored. The written descriptions
survived, so the copy presented every sensitive column with an accurate description *saying*
it was sensitive, with no enforcement behind it. **A reviewer sees a documented,
correctly-labeled table and concludes it is governed.** Description coverage is not label
coverage; only one of them survives data movement. *Found by running a coverage query out of
habit, at the one moment it would show something.*

**A governed table cannot be rebuilt in place — and the error pushes you the wrong way.**
Replacing such a table is refused, because replacing drops columns and a labeled column
cannot be dropped. Dropping the whole table succeeds in one second. So the guard blocks the
path that would have **preserved** the labels and permits both that discard them. The obvious
way to make the error go away is to drop and recreate, which silently converts a governed
table into an ungoverned one. The correct answer is to **separate table creation from data
loading**: create and label once, then refill with an overwrite, which leaves column
definitions — and therefore labels and descriptions — untouched. *Verified by diffing every
label and description before and after a refill: zero differences.*

**A type change turned a mask into an outage, and the builder could not see it.** The
date-of-birth mask returned text. When the curated layer typed that column as a date, the
masked value could no longer be converted back, and the query **failed** for analysts rather
than returning a masked value. Every check in that phase passed — because every check ran as
the owner, who is exempt. One query as a second identity found it. *A type-mismatched mask
does not obscure a column; it denies it, and only to the people it protects.*

**Quality rules do not compose across layers.** Orders were validated against the raw
customer table rather than the validated one, so 237 orders referenced customers that the
curated layer had rejected — while the column description claimed the opposite. Filtering a
parent orphans its children unless the child filters on the parent's **output**. *Found by
testing a claim the documentation made, not a property of the data.*

**Ownership does not apply to objects created later.** Covered in
[section 4](#4-access-control). *Found on a screenshot.*

### Checks that now run as standing controls

| Check | Expected |
|---|---|
| Columns with no `classification` | 0 rows |
| Columns with no description | 0 rows |
| Rows in + rows quarantined − source rows | 0 |
| Orders referencing a customer absent from the curated layer | 0 |
| Objects not owned by the owning group | **exactly one** — the audit log view, by design |

Two of these have caught real defects. A check that has never been seen to fail is not known
to work — so each was confirmed by deliberately introducing the fault it should catch, then
restoring.

### Lineage

Unity Catalog records the data flow automatically from the SQL; nothing declares it. The
captures in `images/` show the full chain with the classification visible on every node,
dropping from `restricted` to `internal` at the aggregation boundary.

Two caveats a reader should not have to discover:

- **Lineage is cumulative, not current.** It records every relationship that has ever
  existed, including ones from builds since replaced, with nothing marking which is live.
  Answering "what feeds this table today" requires filtering by time — and knowing that you
  must.
- **File-to-table lineage has no source table**, since the source is a path rather than a
  table. A query selecting only table names silently drops the ingestion step — the exact
  boundary a provenance question starts from.

---

## 8. What is NOT built yet

Stated plainly, because a runbook claiming coverage it does not have is worse than a short
one.

| Not built | What exists instead |
|---|---|
| **An anonymization workflow** | Masking — protection applied at read time. Genuinely anonymized output, where identifying values are never stored, is the next step. The design is known: replace the maskable date with a birth year or age band, so there is nothing to mask |
| **Compliance control mapping** | Controls that are built and tested, not yet mapped to named SOC 2 or GDPR clauses |
| **Account-level setup** | Metastore creation, identity federation and workspace binding described rather than performed — a single workspace cannot demonstrate them |
| **Cross-platform policy** | Nothing. Expressing the same rules in a second platform, and viewing both through one catalog, is not started |

### One thing done differently because of the environment

This was built on Databricks Free Edition, which is not a metastore administrator. Auditors
would normally be granted read access to the system tables directly. Here that is not
possible, so the audit log is exposed through a **view owned by an identity that can read the
system tables**, granting auditors access to that view alone.

The lab substitution is arguably the better pattern regardless — it exposes only the events
concerning this catalog rather than the whole account — but it was a constraint before it was
a choice, and it is recorded as one.
