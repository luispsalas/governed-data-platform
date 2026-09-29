# Governing a data platform: what the work actually involves

A field guide to building governance that holds, written from one complete build on
Databricks Unity Catalog — and from the things that went wrong in it.

This is not a walkthrough. [The runbook](RUNBOOK.md) is the walkthrough: design, controls, and
how each one was verified, with [every statement](sql/) in run order. This document is about
the decisions underneath — the ones that are the same on any platform, and the ones where
this platform will surprise you.

---

## Contents

1. [What this is, and what it isn't](#1-what-this-is-and-what-it-isnt)
2. [Start from the business, not the catalog](#2-start-from-the-business-not-the-catalog)
3. [The words you need](#3-the-words-you-need)
4. [Classification is the mechanism](#4-classification-is-the-mechanism)
5. [Access control, including the permissions you didn't grant](#5-access-control-including-the-permissions-you-didnt-grant)
6. [Which decisions belong to the business](#6-which-decisions-belong-to-the-business)
7. [Description is first-class, enforcement is second-class](#7-description-is-first-class-enforcement-is-second-class)
8. [Controls that fail silently](#8-controls-that-fail-silently)
9. [Where the design and the platform disagreed](#9-where-the-design-and-the-platform-disagreed)
10. [What only shows up when you use it](#10-what-only-shows-up-when-you-use-it)

---

## 1. What this is, and what it isn't

Governance writing tends to describe finished systems. The controls are listed, the diagram is
tidy, and every rule appears to have been obvious in advance. That is not what building one is
like, and a reader who has only seen the tidy version is badly prepared for the first time a
control passes its own test while protecting nothing.

So this guide reports a build honestly: the design, the reasoning, and the places where the
design met the platform and lost. Roughly a third of what follows exists because something
did not work the way a reasonable person would assume.

**What was built.** One Databricks Unity Catalog environment over synthetic customer data:
a medallion layer from raw files to published aggregates, a classification taxonomy applied to
every column, a privilege matrix across three personas, tag-driven column masks and row
filters, enforced data-quality constraints, anonymization in two forms, and a state-assertion
suite that checks the whole thing in one pass. Every control was tested by signing in as each
kind of user.

**What was not.** Metastore creation and identity federation are described rather than
performed — they need account-level access this build did not have. Compliance control
mapping is not done. Nothing here ran at enterprise scale, on real personal data, or under
a change-management process. **Where this guide states a limit, it is a limit of this build
unless it says otherwise** — and it tries hard to say which.

**Who it is for.** Someone about to build the same thing, or about to review someone else's.
It assumes you can read SQL but not that you know Unity Catalog. Where it names a platform
behaviour, the runbook has the statement that demonstrates it.

> **Coming from Snowflake?** Boxes like this one appear wherever an instinct that serves you
> well in Snowflake will mislead you here. There are more of them than you would expect, and
> the expensive ones are not the obvious ones.

---

## 2. Start from the business, not the catalog

The first artifact of a governance project is not a catalog. It is a short document naming who
consumes the data, which decisions it serves, which rules apply to it, and who may see what.

Skipping it is the most common failure in this kind of work, and it does not look like a
failure. It looks like efficiency: the platform is there, the data is there, so the catalogs
get created and the design accretes from whatever seemed sensible on the day. The result is a
structure nobody can defend, because there is no statement of intent to defend it against.
Ask *"why is this table restricted?"* six months later and the honest answer is *"it was
restricted when I got here."*

Everything downstream derives from this document. The schema layout, the tag vocabulary, the
privilege matrix and the masking rules are all implementations of decisions recorded here —
and when one of them is questioned, this is what you point at.

### The template

Six questions. They take an afternoon with the right people and they save weeks.

| Question | Why it decides something | Answered here as |
|---|---|---|
| **Who consumes this data?** | Determines the persona list, which becomes the group list, which becomes the privilege matrix | Data engineers, analysts, auditors |
| **Which decisions does it serve?** | Tells you which columns must stay *useful* after protection — the constraint that rules out "mask everything" | Revenue reporting by region and month; customer segmentation |
| **Which rules apply?** | Drives the classification taxonomy and the retention questions | Personal data handling; internal analytics only |
| **What may each role see?** | Becomes the row filters and column masks, and the thing you test against | Analysts: no raw identifiers, own region only. Auditors: metadata and access history, no data |
| **Who owns the data?** | Ownership is a *governance* decision, not an administrative one — see §5 | A team, never a person |
| **What must remain possible?** | The most-skipped question, and the one that prevents unusable protection | Counting customers, joining orders, analysing age distribution |

That last question deserves its own paragraph. **Protection that destroys the analytic value
of the data is not a control, it is an outage**, and it gets reversed the first time a
stakeholder complains. It is also the question that produces the interesting design work:

- Masking an email to `***` protects it and answers nothing. Masking it to `r***@example.de`
  keeps the domain, so *"which providers do our customers use"* still works.
- Hashing a national ID consistently means records can still be counted and joined without
  any of them naming a person.
- Storing a birth **year** instead of a birth date supports age analysis and removes the
  identifying precision entirely — and nothing has to be masked, because nothing sensitive was
  stored. (§4 and §7 both return to this.)

Each of those is a business answer, not a technical one. An engineer can implement any of
them; only the business can say which is acceptable.

### The template is also the test plan

Write the answers as statements about what each role may see, and you have written the test:
sign in as that role and check. That is the entire persona-testing method, and it is why the
sixth question matters — *"analysts can still compute average age"* is as much a test as
*"analysts cannot see birth dates."*

---

## 3. The words you need

Governance decisions get signed off by people who do not use the platform. If a decision
cannot be stated without jargon, it cannot be approved — and what gets approved instead is a
vague version that everyone interprets differently.

These are the distinctions that actually caused confusion during this build. Each one is a
place where two words that sound interchangeable are not.

| Term | What it means here | The confusion it causes |
|---|---|---|
| **Privilege** | A specific right on a specific object: `SELECT` on this schema | Often used loosely for all three of the next rows |
| **Permission** | The everyday word for the same thing. Fine in conversation, imprecise in a matrix | Say *privilege* when writing the matrix |
| **Ownership** | A property of an object naming who controls it. **Not a privilege** — the owner bypasses the rules you write | People assume an owner is "just an admin". Owners are exempt from their own masks, which is why owner-run tests prove nothing (§8) |
| **Entitlement** | Account-level capability, like access to compute | Separate from data access entirely: a user can hold every data privilege and still be unable to run a query |
| **Group** | The thing privileges are granted to | Grant to groups, never to people — a privilege granted to a person is invisible in any review that reads the matrix |
| **Role** | A business concept — "analyst" — that you *implement* as a group | Keep the distinction: the role is in the business document, the group is in the platform |

And two platform-specific pairs that look identical and are not:

| | |
|---|---|
| **`BROWSE` vs `USE CATALOG`** | `BROWSE` lets someone see that an object *exists* — names, tags, descriptions — without reading it. `USE CATALOG` is a prerequisite for reading. They are not a hierarchy, and granting one does not imply the other. This cost real time here: an auditor was given metadata discovery and still could not read their own audit log |
| **Mask vs filter vs policy** | A **mask** changes values in a column. A **filter** removes rows. A **policy** is the rule that attaches either one to objects based on their tags. One policy covers every table with a matching tag, including tables that do not exist yet |

> **Coming from Snowflake?** *Role* means something much stronger in Snowflake: roles are the
> primary grantable principal and they nest. Here, groups are the grantable thing and "role"
> stays a business word. If you carry the Snowflake mental model across, you will look for a
> role hierarchy that is not there.

**One usage rule worth adopting.** Say *"the analyst group may read silver"*, never *"the
analyst has access to silver."* Access to *what* — the schema, the rows, the values? This
build had a control that granted access to a table, applied a mask to its contents, and
filtered its rows, and all three were correct while the sentence *"analysts have access to
customers"* was true and useless.

---

## 4. Classification is the mechanism

In a tag-driven model, classification is not documentation. It is the thing the controls match
on: a policy says *"wherever a column is labelled as an email address, mask it this way"*, and
that rule then applies to every table carrying such a column — including tables that do not
exist yet. Get the labels wrong and every control downstream is wrong with them, silently.

### Two keys, not one

The instinct is a single `sensitivity` tag. This build used two, and the separation earns its
keep immediately:

| Key | Answers | Values used here |
|---|---|---|
| `classification` | **Who may see it** | `internal` · `confidential` · `restricted` |
| `pii_type` | **How it is protected** | `name` · `email` · `phone` · `national_id` · `address` · `dob` · `payment_card` |

They are orthogonal. Two columns can share a sensitivity and need entirely different
treatment — an email is partially maskable, a national ID is not — and two columns can share a
masking method while differing in who may see them. Collapse them into one key and you get a
vocabulary that grows by multiplication, one value per combination, which nobody can reason
about by the time it has fifteen entries.

**Tag every column, including the harmless ones.** A column with no tag is ambiguous in
exactly the wrong way: it could be non-sensitive, or it could be unassessed. Tagging
everything makes a missing tag mean one thing — *nobody has looked at this yet* — which is the
only reading a coverage check can act on. `internal` is a classification, not an absence of
one.

### Descriptions are a deliverable, not a courtesy

Every column here carries a plain-language description saying what it holds and why it
matters. This is the part most likely to be cut for time, and cutting it is a governance
decision disguised as a scheduling one: a catalog where objects are labelled but not explained
can be audited for *coverage* and not for *correctness*. Nobody reviewing a tag can tell
whether it is the right tag without knowing what the column actually contains.

Write them for the stakeholder who has to approve the classification, not for the engineer who
already knows. A description that says *"customer email"* adds nothing. One that says *"lower-
cased so counts are honest; masked to first letter plus domain for analysts, which keeps
provider analysis possible"* tells a reviewer what the control costs and what it preserves.

### Read the values from the data — then get the definitions from the business

Two failures here, and they are different failures.

**The first is writing a rule against values you assumed.** A revenue rule built on an invented
status vocabulary matched **zero rows**. The real values were nothing like the guess. One
`SELECT status, COUNT(*) … GROUP BY status` would have prevented it, and it costs nothing.
Worse, the same pass dropped a currency from a six-value list that had *already been verified*
earlier in the same project — **a verified list that exists anywhere you control should be
copied, never retyped.**

**The second is trusting the data as the authority.** Reading values out of the data tells you
what is *present*. It never tells you what is *allowed*, or what each value *means*. Three ways
a data-derived vocabulary is wrong even when it is accurate:

- a valid value **absent from today's data** — a status the business uses quarterly — becomes a
  constraint that rejects legitimate rows;
- a value **present in the data may itself be the defect**, and observing it ratifies it;
- the **semantics** are not in the data at all. Does `cancelled` mean the customer cancelled,
  or the system did? The rule you write depends entirely on the answer.

So: `GROUP BY` first, business sign-off second. Neither alone is sufficient.

This applies to this build's own SQL, and the guide says so rather than hiding it. The quality
constraints here derive their allowed values from **observed synthetic data**, which makes them
a demonstration of the mechanism rather than a governed vocabulary. In a real engagement each
list is a business sign-off, versioned, with a named owner, and changing it is a
change-controlled event — because a constraint turns a vocabulary into something that can
reject production writes. **Deriving an enforced rule from a sample is how yesterday's data
becomes tomorrow's policy without anyone deciding.**

### Classification does not always survive data movement

This is the one that will catch you, and it is covered in full in §7 because it is an instance
of a larger pattern. The short version: **copying a table into another layer can carry its
descriptions while dropping its sensitivity tags.** The copy then looks documented and is
unprotected — and looks *more* trustworthy than an undocumented one.

Re-check classification after every operation that creates a table from another table. Not
because the platform is unreliable, but because the failure is invisible from the outside: the
new table has comments on every column, so it passes the review a human would do.

---

## 5. Access control, including the permissions you didn't grant

### The matrix is only half the picture

A privilege matrix lists what you granted. The system contains what you granted **plus what
was there before you arrived**, and the second half is invisible unless you go looking.

Found here, on a workspace nobody had configured:

| Default | What it meant |
|---|---|
| `account users` held `BROWSE` on every new catalog | Every user in the account could see that every object existed, with its tags and descriptions |
| `All workspace users` held `Can use` on the SQL warehouse | Compute access granted to everyone by default |
| All workspace users held `USE CATALOG` on the workspace catalog, with create rights on its default schema | A writable space nobody had designed |

None of these is a misconfiguration. They are sensible product defaults that make a new
workspace usable. They are also privileges in your system that your matrix does not mention,
and **a matrix that lists only what you granted describes a system that does not exist.**

The practical rule: **enumerate the defaults before granting anything**, decide which to keep,
and record the revocations in the matrix alongside the grants. A revocation is a design
decision and deserves the same visibility — this build revoked `BROWSE` from `account users`
deliberately, and the state-assertion suite now checks that it has stayed revoked, because a
silently restored default would be invisible to every data-level check.

### Grant to groups, and own with groups

Two related rules, and the second is the one that fails quietly.

Granting to a **group** rather than a person keeps the matrix readable: a privilege granted
directly to an individual does not appear in any review that reads the group list. This is
standard and most teams do it.

Ownership is the one that slips. An **owner bypasses the controls you write** — masks, filters,
the lot — so ownership is a governance decision, not an administrative detail. Assign it to a
group so that the exemption belongs to a role rather than to whoever happened to run the
`CREATE` statement.

> **Ownership does not apply forward in time.** This is the single most repeatable finding in
> this build. Transferring ownership of a catalog and its schemas to a group does **not** make
> future objects owned by that group — anything created afterwards belongs to its creator.
> Six tables ended up personally owned here before anyone noticed, and it was noticed by
> accident, on a screenshot, because no query in the test suite had ever asked who owns
> anything. **It then happened again**, months later, in a phase written by someone who knew
> about it, on the single most widely-readable table in the build.

The lesson is not "remember to check ownership." Nobody remembers. The lesson is that
**ownership needs a standing check that runs after every build**, and that the check should
expect *a named set of exceptions rather than zero* — this build has exactly one legitimate
exception, an audit view that must retain an owner able to read the system tables. A check
written to expect zero would flag it forever, and the obvious way to silence that warning is
to transfer it, which breaks the audit view.

> **Coming from Snowflake?** Ownership transfers differently and the inheritance intuition
> does not carry. More importantly, Snowflake's `MANAGED ACCESS` schema — where only the
> schema owner grants privileges — has no direct equivalent here, so the discipline of
> granting through groups is enforced by convention rather than by the platform.

---

## 6. Which decisions belong to the business

Some of what looks like configuration is actually policy, and the difference matters: a
technical decision can be changed by whoever is on call, while a policy decision needs someone
accountable to agree. These are the ones that came up here. Each is a question the platform
cannot answer.

### What counts as anonymized

The most consequential, and the one with the sharpest trap in it.

**Masking, pseudonymization and anonymization are three different promises**, and they are
routinely spoken of as one thing:

| | Reversible by | Failure mode |
|---|---|---|
| **Masking** | Policy — the value is present, the platform hides it | Drop the policy, grant the wrong role, or query as the owner, and it is right there |
| **Pseudonymization** | The key — or by brute force when the keyspace is small | A hash with no secret over customer IDs like `C00001`–`C05000` is reversible in about a second |
| **Anonymization** | Nothing — the information needed to reverse it was never written | Over-generalisation destroys analytic value |

That middle row is where the business decision lives. A hashed identifier *feels* anonymous.
It is a join key, and a join key is a re-identification path waiting for a second dataset. If
linkage is genuinely needed, the honest answer is a pseudonymized table **labelled as such**,
with the secret held somewhere the readers of that table cannot reach.

**And anonymizing changes who may read the data — which means it also bypasses scope controls.**
This build's analyst is restricted to European customers in the curated layer and can read
all-region totals from the anonymized table, because the row filter matches on a tag that
table deliberately does not carry. Whether that is correct depends entirely on what the
restriction was meant to mean:

- *may not see European customers' personal data* — then it is fine;
- *may not know about non-European customers* — then it is a violation that passes every
  technical control.

Those two readings are identical in a privilege matrix and opposite in consequence. **No check
will ever flag the difference.** Somebody has to write down which one was intended, beside the
policy, because the policy cannot express it.

### The other five

| Decision | The question | Note |
|---|---|---|
| **Exemptions and break-glass** | Who is exempt from the controls, and is that visible? | Owners are exempt by construction. Make that an explicit, documented path rather than a side effect |
| **Metadata: discoverable or confidential?** | May people see that a table *exists* without reading it? | Genuinely two-sided — discoverability serves data literacy, and a table name can itself be sensitive |
| **Who may see which regions** | Row-level scope | Needs the *meaning* stated, per the anonymization trap above |
| **Audit retention** | How long is access history kept, and who may read it? | Note the log carries real identities — it is usually the only object in a governance build holding genuine personal data |
| **What the quarantine holds, and who reads it** | Rejected rows keep the defects *and* the original values | This build keeps them readable by analysts deliberately: the count is a data-quality signal. It is a decision, not an oversight, and it is recorded as one |

### How to tell the difference

A useful test: **if two competent engineers could implement it differently and both be right,
it is a business decision.** Whether to enforce k-anonymity at all is a business decision.
Whether `k` is 5, 10 or 20 is a business decision — 5 is a convention, not a law, and a
genuinely public release usually needs more. Whether the constraint is expressed as a `CHECK`
or in the pipeline is a technical one.

Write the business answers down next to the implementation. Not in a separate governance
document nobody opens — **in the column description, in the policy comment, in the table's own
metadata**, where the next person to change the rule will actually encounter it.

---

## 7. Description is first-class, enforcement is second-class

This is the strongest generalisation this build produced, and it took four separate encounters
before it was recognised as one thing rather than four annoyances.

**The pattern: the platform invests heavily in metadata that *describes* data, and
substantially less in metadata that *enforces* rules about it.** Descriptive metadata
propagates, survives operations, and is queryable through the catalog. Enforcing metadata does
not reliably do any of those.

It matters because **your governance reporting is built on the descriptive layer.** Coverage
dashboards, audit exports and review checklists all read the catalog — so they see the half
that behaves well and are blind to the half that does the actual protecting. The reporting
systematically overstates how governed you are, and it does so most confidently where it is
most wrong.

Four instances, sharing no code path:

### 1. Copying a table carries its descriptions and drops its tags

`CREATE TABLE … AS SELECT` — the ordinary way a pipeline builds a curated table — preserves
column comments and loses column tags. The new table therefore arrives fully documented and
entirely unclassified, and no policy matches it because the policies match on tags.

**The surviving half actively reassures the reviewer.** An undocumented table invites
suspicion; a documented, unprotected one does not. This is worse than losing both.

*Why it happens is worth understanding, because it predicts the behaviour:* classification is
a property of the **column definition**, not of the data. A `CREATE … AS SELECT` writes a new
definition, so the tags do not come along. An `INSERT OVERWRITE` into the existing table keeps
the definition and therefore keeps every tag and comment — verified here by diffing every tag
and comment before and after, not by counting them.

### 2. The catalog lists the constraints that do nothing and omits the ones that work

`information_schema` reports primary and foreign keys — which Databricks does **not** enforce —
and does not report `CHECK` constraints, which it **does** enforce. The view that would carry
them is documented as reserved for future use and returns nothing.

So a coverage query over the catalog sees the decorative constraints and misses the enforcing
ones. The enforced rules live in table properties as `delta.constraints.<name>`, readable with
`SHOW TBLPROPERTIES` — and that command returns a result set which is **not a relation**, so it
cannot be joined, unioned or compared. An automated state check can assert the *invariant* a
constraint protects; it cannot assert that the constraint exists.

That gap has a consequence worth stating plainly: **a dropped constraint over clean data looks
exactly like an enforced one.** Constraint existence remains a manual check, and a governance
suite that omits it silently is worse than one that names the hole.

### 3. The documented alternative to policies is weaker at being audited

Views cannot carry row filters or column masks at all. The documented alternative is a
**dynamic view** — access logic written into the view's SQL — and the vendor names its own
drawbacks ([ABAC vs table-level filters and
masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/abac-vs-rls-cm)).
Dynamic views *"lack semantic metadata such as tags or policy definitions in system tables,
which makes them harder to audit at scale."* And more sharply: *"Because they lack a
SecureView barrier, they don't protect against probing attacks, where a user crafts a
predicate with side effects to infer information about filtered rows."*

Read that carefully. The recommended fallback moves your access logic **out** of the metadata
layer and **into** query text, where no catalog query can find it. The protection may be
identical; the auditability is not.

### 4. Enforcement metrics land somewhere else again

Pipeline quality expectations record their results in a pipeline event log — a fourth
location, separate from the catalog, from table properties and from the policy list. Nothing
joins them. Answering *"what is enforced on this table, and is it working?"* means querying
four different places in three different ways, and only one of them is the catalog everyone
thinks of as the governance surface.

### What to do about it

- **Never infer enforcement from the catalog.** Coverage of tags and descriptions is evidence
  about description, and nothing more.
- **Keep an inventory of enforcing metadata that the catalog cannot show you** — constraints,
  policies, expectations — and check it separately. It will be a manual list. Write it down
  rather than pretending the automated report covers it.
- **Prefer mechanisms whose state is queryable** when the choice is otherwise even. A tag-
  matched policy you can enumerate beats logic embedded in a view you cannot.

> **Coming from Snowflake?** The asymmetry exists there too, but it lands differently.
> Snowflake enforces only `NOT NULL` and treats other constraints as informational, so nobody
> expects the catalog to describe enforcement — the expectation never forms. Here, `CHECK`
> constraints genuinely **are** enforced, which makes their absence from the catalog far more
> surprising and far more likely to be missed.

---

## 8. Controls that fail silently

Read this section before the two that follow, and refer back to it from every control you
design. It is the single most useful idea in this guide.

**A control that is wrong and a control that is right look identical from the seat that built
it.** That is not a platform flaw. It is a structural property of how governance is
administered: the person configuring the controls is usually exempt from them, so the view
they use to verify their work is the one view where the work is invisible.

Every significant defect in this build was of this shape. None was found by a check written to
find it.

### What it looks like

| What happened | Why it was invisible |
|---|---|
| A column mask, applied to a column whose type it did not expect, made the column **unreadable** instead of masked | Owners bypass their own masks, so every owner-run check passed while the analyst persona could not query the table at all |
| Six tables ended up personally owned (§5) | No query had ever asked who owns anything; found by chance on a screenshot |
| A copied table arrived documented and unclassified (§7) | It looked *more* trustworthy than an undocumented one |
| A coverage check reported zero unclassified columns | The catalog view is permission-filtered, so "nothing unclassified" and "nothing visible" produce identical output (§9) |
| A governance check reported no grants outside the privilege matrix | Its query returned an empty set because of a filter bug, so it had nothing to compare and passed |

That last one is the purest example, and it was found in the very suite written to catch
problems like it. **A check whose clean result is an absence can pass by being blind.**

### Four design moves

**1. Test as a second identity, always.** An owner-run pass proves nothing about access
control. This is the cheapest and most effective move available: create one extra account, add
it to each persona group in turn, and read. It found every access defect here, and none of
them were visible any other way.

*Practical warning:* if you run two browser sessions, make them visually distinct — different
themes — and still confirm with `current_user()` in the same pane before trusting a result.
Screenshots from two sessions are indistinguishable, and misreading which identity produced a
result caused two wrong findings here before it was caught.

**2. Give every absence-shaped check a positive control.** If a clean result means *zero rows*,
the check must also assert how many objects it expected to inspect. Otherwise a narrowed
identity, a filter bug or a permission change produces a *greener* report — less access looking
like better governance. State the expected number and let seeing fewer be a failure.

**3. Verify in two parts, and say which you did.** Firing proves a check *works*; only
switching it off proves it was *needed*. A check can fire correctly on a seeded fault and still
be worthless because something else already caught it — that is dead code that looks
well-tested. Run both halves, and when reporting a control, state which half you actually ran.

**4. Never let a check's failure path and its negative result be the same value.** A query that
returns zero rows when it finds nothing *and* zero rows when it cannot see anything cannot
distinguish them, and it will report the reassuring one. Return three outcomes where you can —
found, absent, could not determine — and make the third loud.

### The worked example

This build ends with a state-assertion suite: one re-runnable script checking the entire
intended end state, emitting one row per control with `expected` and `actual` side by side.
Twenty controls covering structure, ownership, metadata coverage, tag vocabulary, the full
privilege matrix, policies and data invariants.

Two things about it are worth more than the suite itself.

**It was built from the design, not from the phases.** Per-phase checks verify what that phase
was thinking about. The two defects this suite found on its first run were both in objects
created by a phase that was thinking about something else — one unclassified, one personally
owned. **A whole-state check is the only thing that catches what no phase had in mind.**

**It was fault-seeded before it was trusted.** Ten controls were each given the defect they
claim to catch; all ten fired; every seed was reversed and the reversal verified. Before that,
twenty green rows on a build already believed correct were worth nothing.

And the honest part: **the suite failed four times on its first run, and every failure was the
suite's own defect rather than the system's** — a dropped value in an expected list, a filter
testing `IS NULL` against a column holding the string `'NONE'`, a missing exclusion in one
branch of a union, and a check rendering its good news as a blank cell. Three of those four
would have produced **false confidence** rather than a false alarm.

Which is the last rule, and the one to carry into any review: **an assertion suite has exactly
the failure modes of the code it checks.** The first question on any red row is not *what is
broken* — it is *which side is wrong*.

---

## 9. Where the design and the platform disagreed

Places where a reasonable design assumption met the platform and lost. Each states what was
expected, what actually happened, and where to find the statement that demonstrates it.

These are not complaints. They are the specific points where someone building the same thing
will lose a day, and most of them have a sound reason behind them once you know it.

### Rebuilding a governed table

**Expected:** a table can be rebuilt in place.
**Actual:** `CREATE OR REPLACE TABLE` is refused — `CANNOT_DROP_TAGGED_COLUMN`. Replacing a
table drops its columns, and a governed-tagged column cannot be dropped. `DROP TABLE` on the
same object succeeds in a second.

**So the guard blocks the one path that would have preserved the classification and permits
both paths that discard it** — and the error text routes you toward `DROP` + `CREATE`, because
that is what makes it go away. The correct answer is `INSERT OVERWRITE`, which keeps the column
definitions and therefore keeps every tag and comment. See [`sql/09_silver.sql`](sql/09_silver.sql).

### Quality rules do not compose across layers

**Expected:** filtering bad rows out of a parent table protects the children built from it.
**Actual:** it orphans them. Rejecting 60 customers from the curated layer left 237 orders
pointing at customers that no longer existed there — because the orders build was joining to
the *raw* layer, where those customers still existed.

The fix is to join child to parent **within the same layer**, so the child inherits the
parent's rejections. The general form: **a filter applied at one layer does not propagate; the
next layer must filter on the previous layer's output, not on the source.** See
[`sql/09_silver.sql`](sql/09_silver.sql).

### Dropping a materialized view is not transitive

**Expected:** dropping an object removes what it created.
**Actual:** creating one materialized view creates **three** objects — the view, a backing
table, and a pipeline event log, the last two undeclared and unnamed by the statement.
Dropping the view leaves the other two behind as orphans in a governed schema.

They can be removed by hand, and they can be classified like any table. But a schema's object
set changes as a side effect of declaring a transformation, so **re-run your coverage checks
after pipeline work, not only after table work.** See
[`sql/16_anonymize_gold.sql`](sql/16_anonymize_gold.sql).

### Lineage is cumulative, not current

**Expected:** the lineage graph shows what feeds a table.
**Actual:** the system table is an append-only history of operations. A superseded edge from a
build that was dropped and replaced sits beside the corrected one, with nothing marking which
is live. An auditor reading it raw gets every answer the table has ever had.

The UI is not silent about this — the graph has a time-window selector — but the **system
table applies no window by default**, so SQL-based lineage queries and anything built on them
return every edge ever recorded. **Lineage answers "what has ever fed this"; only a timestamp
filter turns it into "what feeds this."** See [`sql/10_gold_lineage.sql`](sql/10_gold_lineage.sql).

### File-to-table lineage has no source table

**Expected:** every lineage edge names a source and a target.
**Actual:** an edge from a file to a table carries a null source table, so the obvious query —
join source to target — silently drops the ingestion boundary. The point where external data
enters your governed estate is the edge most worth auditing, and it is the one a naive query
omits.

### A system table's own documentation understated its values

**Expected:** a column's documented enumeration lists its values.
**Actual:** an `entity_type` column returned a value its own comment does not list.

This is the vendor committing, in the documentation for the field, the same error §4 warns
against. **A documented enumeration is a claim about the data, not the data** — validate
against the data even when the source of the list is the platform itself.

### Scope leaks where values do not

**Expected:** an aggregate layer with no personal data needs no classification.
**Actual:** an untagged aggregate can leak **scope** rather than values — which rows were
included, which segment a figure covers — and that is invisible to a review asking *"does this
hold PII?"* because the answer is honestly no.

Classify aggregates for what they reveal about the population, not for what they store.

### Re-running a maintenance script strands access

**Expected:** re-running a script is harmless.
**Actual:** a section that revokes access, changes a schema, then restores access will, on a
second run, revoke successfully and then **fail on the statement that operates on the
already-changed object** — stopping after the revoke and before the restore. Two roles lost
read access and nothing reported it.

It failed *because* the change had already been applied, so the re-run was guaranteed to
strand access every time. **A script that is safe exactly once and harmful on every subsequent
run is worse than one that is never safe, because the first success teaches you it works.**
Guard destructive sections so a re-run is a no-op: one query asserting the pre-change state,
and stop if it does not hold.

### A column added in place lands somewhere else than in your script

**Expected:** adding a column to a table and adding it to the build script produce the same
schema.
**Actual:** `ALTER TABLE … ADD COLUMN` appends to the **end**; the obvious edit to a build
script replaces the old column **in place**. `INSERT OVERWRITE` matches columns by **position**.
The next scheduled load would have written birth years into a consent flag — quietly, with no
type error to stop it.

Each file was correct read on its own. **Only the pair was wrong, and nothing in the platform
compares them.**

---

## 10. What only shows up when you use it

Findings with no documentation problem behind them — they simply do not appear until someone
runs the thing. Collected here because they cost time and none of them is discoverable by
reading.

### Access changes are not instant, and different gates update at different speeds

A group membership change reached the compute gate before it reached the function that
reports membership: queries ran while `is_account_group_member()` still returned false.

**A denial observed during that window looks exactly like a correctly-enforced denial.**
Re-check membership until it reads true before trusting any access test — and in a guide or a
runbook, **state the wait explicitly**. Users get anxious about whether access has actually
been granted, and a document that omits the delay turns a normal propagation lag into a
suspected misconfiguration.

### A populated table can show "No data" in the UI

The Sample Data tab reported no data for a table that contained 5,000 rows. Nothing was wrong
with the table. If you verify a load by looking at that tab, verify it with `COUNT(*)` instead.

### The same privilege is spelled two ways

`SHOW GRANTS` displays `USE SCHEMA`; `information_schema` stores `USE_SCHEMA`. Same catalog,
same privilege, space versus underscore. An expected-value list built from one surface will
mismatch every row when compared against the other — eleven of nineteen, in this build's
assertion suite.

The same inconsistency appears in column names: `information_schema.tables` names the schema
column `table_schema`, while `information_schema.column_tags` names it `schema_name`. A query
joining them needs both spellings.

### `DROP POLICY` takes no `IF EXISTS`

Unlike `DROP TABLE`, `DROP VIEW` and `DROP FUNCTION`, the ABAC form has no `IF EXISTS` clause —
the parser reads `IF` as the policy name. **Policy teardown cannot be made idempotent the way
table teardown can**, so a re-runnable environment script will error on an already-dropped
policy rather than passing quietly.

### A failing statement cancels everything after it

In a batch, an error stops execution — so in a test suite that deliberately contains expected
denials, **a denial silently cancels every check below it.** A suite can report a pass having
skipped half of it. Run positive controls separately from anything expected to fail.

Relatedly: a suite containing intended denials **cannot be judged by its own run status.** The
editor reports "Last execution failed" when a control works correctly. Wrap expected denials so
the *absence* of an error is the failure, or a reader takes a working control for a broken
script.

### Retiring a control takes three steps, not two

Removing a masking rule means dropping the **policy**, dropping the **function** it calls, and
removing the **value from the governed tag's allowed list**. Doing only the first two leaves a
vocabulary entry with nothing behind it — so a column can be tagged tomorrow for a control
retired today, and it will pass every coverage check as a classified column while being
protected by nothing.

Only the third step makes the retirement preventive. With it, the platform refuses the tag at
write time and names the allowed values in the error.

### Governed tags carry their vocabulary twice

A governed tag has an enforced list of allowed values **and** a free-text description that
usually lists them too. Nothing keeps the two in step. Here they disagreed for days — the
description listed seven values while the policy enforced eight — and the description is what
a human reads to learn what is allowed.

### Features can be present and simply unused

Two governance features were assumed unavailable on this tier and turned out to be sitting in
the console, one of them a single button away from being enabled. **Do not infer a platform's
limits from what a SQL session can reach.** Open the console and look before writing "not
available" in a document someone will rely on.
