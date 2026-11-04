## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles; label strings match role names. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root and ADRs in `docs/adr/`. See `docs/agents/domain.md`.

## Project constraints

### UI fidelity (locked)

my-comic UI must use the same design and aesthetic as Fushi v3.0.0. Preserve the original Fushi shell, components, theme, and layout; only hide or remove non-manga entries. Do not replace, restyle, or simplify the UI without explicit user approval. See `docs/adr/0008-ui-fidelity-constraint.md`.
