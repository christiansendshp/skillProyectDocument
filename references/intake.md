# Intake questionnaire

Use when starting a brand-new app/system/product (see "Building a new app or
product" in `SKILL.md`) or when installing the skill mid-project and Product or
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

Glossary:

8. Any domain term that means something specific here (or differs between
   frontend/backend/DB naming) that the whole team should use consistently?

Out of scope:

9. What is explicitly not being built (this phase)?

## Stack (-> `Stack_Tecnologies.md`)

Operational summary:

10. Stack base, runtime, datastore, and deploy target, in one line each, if
    already decided?

Architecture & Data:

11. Monolith, services, client/server split, required third-party
    integrations, module boundaries, data schema — anything already
    decided?

Critical commands:

12. How will tests run? Lint/typecheck? Build? Migrations? Dev server?

Environment variables & secrets:

13. Names and purpose only (never values) of configuration the system will
    need.

Technical decisions:

14. Any architectural decision already made that a later agent shouldn't
    second-guess without cause?

## After the answers

1. Fill Product/Stack with confirmed answers (`CONFIRMED`); mark anything
   still unresolved `UNKNOWN` or `HYPOTHESIS` with where to verify it —
   never `N/A` or any other value.
2. Build the `## Plan` in `Roadmap.md`: a `### Fnn — <phase>` heading, an
   `#### Fnn-Enn — <epic>` heading under it, and a task-row table
   (`Fnn-Enn-Tnn`) from the flows and rules above.
3. Leave the first actionable task's row `TODO`, ready for `claim`.
4. Do not block a small, unrelated task on this questionnaire — only run it
   for a new app/product or a fresh mid-project install (see `SKILL.md`).
