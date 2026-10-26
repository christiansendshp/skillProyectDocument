# Factory mode

Factory mode turns the protocol into a production line: an agent picks work,
decides, tests, is reviewed by another agent and closes, with a human only
looking at red lines, asynchronously. It is opt-in and enforced by the scripts.
The full design is in `docs/features/ia-factory.md` (decisions D-01 to D-21 are
ADR-023 to ADR-043 in `docs/Stack_Tecnologies.md`).

## Activation

Factory mode is on when the project `AGENTS.md` has a `## Factory` section
whose `Mode` is `FACTORY`. Without the section, or with `Mode` `CLASSIC` (or any
value that is not `FACTORY`), every command behaves exactly as it did before
Factory mode existed (BR-008).

```markdown
## Factory

| Setting | Value |
|---|---|
| Mode | FACTORY |
| WIP per agent | 1 |
```

A row that is missing, empty or just an em dash takes its default:

| Setting | Default |
|---|---|
| Mode | FACTORY (when the section exists) |
| Require TDD | YES |
| Independent review | YES |
| WIP per agent | 1 |
| Max fix attempts | 3 |
| Fast lane max files | 5 |
| Fast lane max lines | 150 |
| Fast lane protected paths | prisma/ migrations/ auth/ rls/ security/ |
| Preferred reviewer | (empty) |
| Fallback reviewer | (empty) |
| Recall budget bytes | 4096 |
| Brain max entries | 80 |

`PROJECT_DOCS_MODE=classic` or `factory` overrides the file (it exists for
tests and for forcing one mode from a script); any other value is ignored.

`mode <project>` prints which mode applies and where it came from (`env`,
`AGENTS.md` or `default`); in Factory mode it also prints every effective
setting, one `Name = value` line each.
