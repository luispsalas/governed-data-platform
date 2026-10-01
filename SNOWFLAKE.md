# Snowflake ↔ Databricks: a governance crosswalk

Two halves. **Part 1** is what differs between the two governance models, scoped to differences
that change a design decision rather than a feature inventory. **Part 2** is how the two
platforms actually connect, because a plan to integrate them hides four quite different
architectures with different governance consequences.

Written from the Databricks side. Everything here was checked against current vendor
documentation; where the documentation does not answer a question, this says so rather than
inferring.

---

## Part 1 — Governance differences that change a design

### The assumption to drop first

**Both platforms do tag-driven policy.** It is tempting to assume that Databricks has ABAC while Snowflake has
only hand-applied masking policies, and that is wrong: Snowflake has had tag-based masking
for years, and documents tag-based policies as attribute-based access control. (Tag-based
*row access* policies are still in public preview as of October 2026, per the
[ABAC using tag-based policies](https://docs.snowflake.com/en/user-guide/tag-based-policies) page;
a row access policy attached directly to a table is generally available.) The
two models are genuinely similar in intent. **The differences are mechanical, and the
mechanics are where designs break.**

### The one that matters most: what binds a policy to a column

| | Databricks Unity Catalog | Snowflake |
|---|---|---|
| Policy is bound to | a **tag value**, matched in the policy body (`has_tag_value('pii_type','email')`) | the **tag itself** (`ALTER TAG … SET MASKING POLICY …`) |
| Which policy applies | chosen by the **value** of the tag | chosen by the column's **data type**, matched against the policy signature |
| One tag, many policies | one policy per value | one tag can carry several policies, each selected by data type |

So the vocabularies mean different things. In Unity Catalog `pii_type` is a set of *values*
(`email`, `phone`, `national_id`) and each value earns a policy. In Snowflake a tag is closer
to a single classification whose protection varies by the *type* of the column carrying it.

**And the failure modes are opposites, which is the expensive part.**

When a policy and a column disagree on type:

- **Snowflake fails open.** The documentation is explicit that when the data type does not
  match the policy signature, the policy *does not apply to that column*. No error. The column
  is tagged, looks governed on every inventory, and returns raw values.
- **Databricks fails closed.** This build hit exactly that case: a type-mismatched mask does
  not silently skip the column, it **denies** it — and denies it invisibly to the owner, who
  is exempt from the mask and sees nothing wrong.

Both are dangerous and they need opposite checks. In Snowflake, verify that a tagged column is
actually *protected*, because tagging it proves nothing. In Databricks, verify that a governed
column is still *readable by the people who should read it*, because a broken mask presents as
a permission problem for someone else. **A reviewer who has only worked on one platform will
bring the wrong instinct, and the wrong instinct is silent in both directions.**

### Where the vocabulary lives

| | Unity Catalog | Snowflake |
|---|---|---|
| Tag scope | **account-level** governed tags | **schema-level** objects, referenced by path |
| Allowed values | enforced at `SET TAGS` time and at policy compile time | tags may define allowed values |
| Consequence | one vocabulary, centrally governed, hard to fork | vocabularies can proliferate per schema |

The Databricks model makes the taxonomy a governed object in its own right. This build leaned
on that hard: the assertion suite validates every tag value against the allowed list, and
retiring a value turned out to need **three** steps — drop the policy, drop the function, and
remove the value from the governed tag — because the vocabulary outlives the control.

### Grants: inheritance versus future grants

| | Unity Catalog | Snowflake |
|---|---|---|
| New objects | a grant on a catalog or schema **automatically applies to current and future children** | `GRANT … ON FUTURE TABLES IN SCHEMA …`, stated explicitly |
| Precedence | traversal: you need `USE` on every parent to reach a child | where future grants exist at both database and schema level, **schema-level wins and database-level is ignored** |
| Principals | groups | roles, which **inherit through a role hierarchy** |

Two costs here, in opposite directions.

**Coming from Snowflake, you will look for future grants and not find them** — and may conclude
Unity Catalog cannot express the intent. It can; it is the default. The real hazard is the
reverse of the one you are used to: `SELECT` on a schema is not a statement about today's
tables, it is a standing grant over everything created there afterwards. That is precisely why
the assertion suite in this build asserts that **no grant exists outside the matrix**, rather than
only checking that the intended grants are present.

**Coming from Databricks, you will under-model Snowflake's role graph.** Unity Catalog groups
do not inherit privileges from each other the way roles do, so a design that is one flat
membership decision here becomes a hierarchy decision there.

### Two differences this build ran into directly

| | Unity Catalog | Snowflake | Cost of assuming |
|---|---|---|---|
| `CHECK` constraints | **enforced** on Delta tables; a violating write fails | **enforced** on standard tables since April 2026 (*"Check constraints are always enforced"*, [Overview of constraints](https://docs.snowflake.com/en/sql-reference/constraints-overview); generally available in release 10.12). A NULL result lets the row through on both. `COPY INTO` a table with CHECK constraints fails, so they belong downstream of the raw load. Unlike Unity Catalog, Snowflake lists them in `INFORMATION_SCHEMA.CHECK_CONSTRAINTS` | The controls port. The trap is now age: Snowflake designs older than April 2026 treat CHECK as documentation. *This row said "not enforced" until October 2026; corrected against the docs.* |
| Secure views | no equivalent | `SECURE VIEW` | The documented Databricks alternative to policies is a dynamic view, and the vendor names its own drawbacks on the [ABAC vs table-level filters and masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/abac-vs-rls-cm) page: dynamic views *"lack semantic metadata such as tags or policy definitions in system tables, which makes them harder to audit at scale,"* and *"Because they lack a `SecureView` barrier, they don't protect against probing attacks."* |

Worth recording the *samenesses* too, or a crosswalk teaches distrust of instincts that are
sound: primary keys, foreign keys and uniqueness are informational on **both** platforms.
Neither enforces them.

---

## Part 2 — How the two platforms actually connect

Four patterns, and they are not variations on one idea. **The question that separates them is
whose engine runs the query**, because that decides whose governance applies.

### Direction 1 — Databricks reads Snowflake

**Pattern A: Query federation (Lakehouse Federation).** Unity Catalog holds a connection and a
*foreign catalog* mirroring a Snowflake database. The query is pushed down over JDBC and
**Snowflake executes it**. Read-only. Access is governed on the Databricks side through the
foreign catalog like any other securable.

Because Snowflake runs the query, Snowflake's own policies are still in the path. You get two
layers of governance, and the effective permission is the intersection. Documented use: on-demand
reporting and proof-of-concept ETL work.

**Pattern B: Catalog federation.** Unity Catalog federates the Snowflake *catalog*, but **the
query runs on Databricks compute directly against object storage** — the [documentation](https://docs.databricks.com/aws/en/query-federation/snowflake-catalog-federation)
is explicit that the query *"is only executed using Databricks compute."* Documented use: incremental
migration without changing code, or a long-term hybrid.

Two things to know before choosing it:

- **It supports Snowflake-managed Iceberg tables only.** Non-Iceberg Snowflake tables are not
  eligible and always fall back to query federation.
- **The governance question is not answered by the documentation.** If Snowflake's engine never
  runs, Snowflake's masking and row access policies cannot be applied at query time — that is
  the obvious inference, and it is an inference, not a documented statement. The Databricks page
  specifies the Unity Catalog permissions required and is silent on whether Snowflake-side
  policy is enforced or bypassed.

  **Do not deploy this pattern over policy-protected Snowflake data without testing it
  directly**, with a persona that Snowflake's policies actually restrict, reading the same table
  both ways. If the two disagree, catalog federation is a governance bypass wearing the clothes
  of a performance optimization. That test is cheap and nobody has an excuse for skipping it.

### Direction 2 — Snowflake reads Databricks

**Pattern C: Iceberg REST catalog integration.** Snowflake's `CREATE CATALOG INTEGRATION`
points at Unity Catalog's Iceberg REST endpoint. Two credential models: **vended credentials**
(`ACCESS_DELEGATION_MODE = VENDED_CREDENTIALS`), where Unity Catalog issues Snowflake temporary
credentials and no Snowflake-side external volume is needed; or an **external volume**, required
when the remote catalog does not support vending.

**Pattern D: Catalog-linked database.** A Snowflake database bound to the external Iceberg REST
catalog, which **automatically syncs** — Snowflake detects namespaces and Iceberg tables and
registers them. The difference from C is standing versus per-table: a linked database tracks the
catalog as it changes rather than exposing a fixed set.

Write support has expanded: writes from Snowflake to externally managed Unity Catalog Iceberg
tables reached general availability on Azure storage in April 2026, having been AWS-only before.

### The governance consequence, which is the point of Part 2

**Credential vending moves the enforcement boundary.** A vended credential is used by the
external engine directly against cloud storage, and Unity Catalog does not govern or log reads
performed that way. The audit record covers the moment access was *authorized*, not each read
that follows.

For a build like this one — all managed tables, nothing externally accessed — that costs
nothing. The moment an external engine is reading your tables, the question of who read this data stops being
one your catalog can answer on its own, and the honest answer involves cloud storage
logs. **Plan the audit story before enabling the integration, not after someone asks for it.**

---

## What is not covered here

- **Delta Sharing**, and whether Snowflake can consume it. Not verified, so not claimed.
- **Performance and cost.** Federation carries overhead and pushdown varies by source; this is
  a governance document.
- Anything requiring a Snowflake account to confirm. Part 1 is read from documentation, not
  from a build. A hands-on replica is a separate, larger exercise, and until it exists **treat
  the Snowflake column as researched rather than tested** — which is the opposite of how the
  rest of this repository is sourced, and the reason this file says so at the top and again
  here.

---

## Sources

Checked September 2026; the `CHECK` row and the tag-based row access note re-checked October 1, 2026. Every claim above traces to one of these; where they are silent, this
document says so rather than filling the gap.

**Databricks** — [Unity Catalog best practices](https://docs.databricks.com/aws/en/data-governance/unity-catalog/best-practices) ·
[ABAC in Unity Catalog](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/) ·
[ABAC vs table-level row filters and column masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/abac/abac-vs-rls-cm) ·
[Unity Catalog permissions model concepts](https://docs.databricks.com/aws/en/data-governance/unity-catalog/access-control/permissions-concepts) ·
[Connect to external databases and catalogs](https://docs.databricks.com/aws/en/query-federation/) ·
[What is catalog federation?](https://docs.databricks.com/aws/en/query-federation/catalog-federation) ·
[Enable Snowflake catalog federation](https://docs.databricks.com/aws/en/query-federation/snowflake-catalog-federation) ·
[Run federated queries on Snowflake](https://docs.databricks.com/aws/en/query-federation/snowflake) ·
[Credential vending for external system access](https://docs.databricks.com/aws/en/external-access/credential-vending)

**Snowflake** — [Tag-based masking policies](https://docs.snowflake.com/en/user-guide/tag-based-masking-policies) ·
[ABAC using tag-based policies](https://docs.snowflake.com/en/user-guide/tag-based-policies) ·
[Introduction to object tagging](https://docs.snowflake.com/en/user-guide/object-tagging) ·
[Understanding row access policies](https://docs.snowflake.com/en/user-guide/security-row-intro) ·
[Overview of constraints](https://docs.snowflake.com/en/sql-reference/constraints-overview) ·
[Overview of access control](https://docs.snowflake.com/en/user-guide/security-access-control-overview) ·
[Configure a catalog integration for Unity Catalog](https://docs.snowflake.com/en/user-guide/tables-iceberg-configure-catalog-integration-rest-unity) ·
[Use a catalog-linked database](https://docs.snowflake.com/en/user-guide/tables-iceberg-catalog-linked-database)
