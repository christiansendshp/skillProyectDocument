# Intake questionnaire

Use when starting a brand-new app/system/product (see the "quiero una app"
flow in `SKILL.md`) or when installing the skill mid-project and Product or
Stack stay mostly `UNKNOWN` after reconstruction from code.

Fill every field first from what the user already said or what the project
reveals (manifests, `docker-compose`, schemas, tests, config, TODOs). Ask the
user only the fields still missing, in one batch, grouped as below. Never
re-ask a field already answered. Whatever stays unanswered is recorded as
`UNKNOWN` with a verification step, per `SKILL.md`; do not block on it.

## Product (-> `ProductDescription.md`)

Operational summary:

1. What is the product, in one line?
2. Who is the primary user?
3. What is the core outcome it delivers?
4. Is there a critical invariant it must never violate (data loss, money,
   safety, compliance)?

Users and outcomes:

5. What other user roles exist, and what outcome does each need?

Business rules:

6. Are there rules the system must always enforce? List them.

Main flows:

7. What are the two or three flows that matter most, start to outcome?

Out of scope:

8. What is explicitly not being built (this phase)?

## Stack (-> `Stack_Tecnologies.md`)

Runtime:

9. Language/framework and version, if already decided?

Architecture:

10. Monolith, services, client/server split — anything already decided?

Data:

11. Datastore(s), if already decided?

Components:

12. Any required third-party integration or component?

Commands:

13. How will tests run? How will it lint or type-check?

Delivery:

14. How does this ship — deploy target, packaging, CI?

Environment variables:

15. Names only (never values) of configuration the system will need.

## After the answers

1. Fill Product/Stack with confirmed answers; mark anything still unresolved
   `UNKNOWN` with where to verify it.
2. Build the `## Plan` in `Roadmap.md` (`PHASE`/`EPIC`/`TASK` entries, per
   `references/roadmap-schema.md`) from the flows and rules above.
3. Set the first actionable task's `status` to `READY`.
4. Do not block a small, unrelated task on this questionnaire — only run it
   for a new app/product or a fresh mid-project install (see `SKILL.md`).
