# ADR 0006 — One repository for the Wick stack

**Status:** Accepted
**Date:** 2026-07-30

## Context

[ADR 0004](0004-wick-coap-as-sibling-library.md) split CoAP out of Wick into a sibling library. That decision was about **package** boundaries — what belongs in a library that claims to be LwM2M primitives, and what belongs in one that claims to be generic CoAP — and it stands.

It was implemented as two separate git repositories, `Finnlytics/wick` and `Finnlytics/wick_coap`, which is a different decision that was never examined. Once the remaining three LwM2M interfaces landed, three problems with it became concrete rather than theoretical:

**1. The path dependency was already assuming co-location.** `wick/mix.exs` resolves its `wick_coap` test dependency like this:

```elixir
if File.exists?("../wick_coap/mix.exs") do
  [path: "../wick_coap", only: :test]
else
  [github: "Finnlytics/wick_coap", branch: "main", only: :test]
end
```

That relative path only works because the two repositories happen to be checked out as siblings. Two repositories that must sit next to each other to be developed is a monorepo with extra steps and no enforcement.

**2. CI could not test a cross-library change.** The fallback branch means CI tested Wick against whatever `wick_coap` `main` happened to be, never against the working copy. During the interface work, Wick and WickCoap were simultaneously on separate feature branches; CI would have tested against neither.

**3. Cross-library changes are normal, not exceptional.** Adding Observe-Composite to Wick is what surfaced the fact that `WickCoap.Endpoint` keys server-side Observe relations by `{peer, uri_path_segments}` — which means two Composite observations from one peer collide, because Composite operations target the root. Finding that required both libraries in hand at once. There is no reason to expect this to be the last such case: a protocol library and the transport beneath it move together.

Separately, the two demo applications (`wick_demo_server`, `wick_demo_client`) had **no version control at all**. They lived inside an unrelated, un-versioned working tree, which is how roughly 2,600 lines of working code — including the entire web UI — came to be untracked.

## Decision

One repository, **`wick-stack`**, containing both libraries and both demos:

```
wick/                    → hex: wick
wick_coap/               → hex: wick_coap
demo/wick_demo_server/
demo/wick_demo_client/
```

Both libraries remain separate Mix projects and separate Hex packages. Nothing about ADR 0004 changes; only the number of git remotes does.

The directory layout is chosen so that **every existing relative path dependency keeps working unmodified**: `wick` → `../wick_coap`, the demos → `../../wick` and `../../wick_coap`, and `wick_demo_client` → `../wick_demo_server`. Migration therefore required no `mix.exs` edits, which is the cheapest possible way to make a change this structural.

CI becomes one workflow with one job per project, all built from the same commit.

### History was not preserved

The repository starts from a single fresh commit rather than importing the two prior histories.

That is a real cost — eight commits of Wick history and four of WickCoap are not carried over — accepted for a specific reason. Wick's history contained two early scoping documents (`docs/01-elixir-lwm2m-initial-assessment.md`, `docs/02-elixir-library-plan.md`) that referenced private sibling projects by path and name, along with commercial reasoning about them. Those files were deleted in a later commit, but deletion does not remove content from history, and the commits containing them had been pushed to a public repository. Importing that history into the new repository would have carried the problem forward.

Starting clean removes it from this repository unconditionally, with no filter-branch, no rewritten SHAs, and nothing to get subtly wrong. The prior repositories still exist and still hold the history for anyone who needs it.

## Consequences

**Good**

- A change spanning both libraries is one commit, one review, one CI run.
- The relative path dependency is now guaranteed rather than incidental, and the GitHub-branch fallback can eventually be deleted.
- The demos are under version control, and are built by CI against the same commit as the libraries they consume.
- One obvious entry point. A reader arriving at the stack sees a README that explains all four projects and how to run them, which no single-library README could.

**Bad**

- Two GitHub repositories to consolidate, and their issues and stars do not merge. Cheap now, while both are pre-release and unpublished on Hex; it would not stay cheap.
- Publishing is per-directory (`cd wick && mix hex.publish`), which is one more thing to remember than a repository whose root *is* the package.
- Twelve commits of history are not carried into this repository. See above for why that was the right trade here.

**Neutral**

- Hex is indifferent to this. Multiple packages from one repository is well-trodden — `elixir-nx/nx` publishes `nx`, `exla`, and `torchx` from one tree. Wick's only dependency on WickCoap is `only: :test` and its package `files` list excludes `test/`, so consumers never resolve it at all.
- Not an Elixir umbrella project. Umbrellas share a build and a config, which is wrong for libraries that are published and consumed separately. These are independent Mix projects that happen to share a repository.

## References

- [ADR 0004 — `wick_coap` as a sibling library](0004-wick-coap-as-sibling-library.md) — the package boundary this decision does *not* alter
- [ADR 0005 — CoAP option numbers as the Wick/transport boundary](0005-coap-option-tuples-at-the-wick-boundary.md)
- [`elixir-nx/nx`](https://github.com/elixir-nx/nx) — prior art for several Hex packages in one repository
