# How we work

This is the working philosophy behind every repo Daniel Cuesta builds, with AI pair programmers and with collaborators like Izaiah. Much of it comes from JP Burford's course *Shipping Code in the Age of AI* (Notre Dame, fall 2026). Pull requests are where you can see it in practice.

## Every idea is a pull request
- **Branches:** `main` is production and `dev` is where features meet. Work happens on a feature branch cut from `dev`, one feature or fix per branch.
- **Never commit to `main` directly.** Changes reach it only through a reviewed dev → main release PR.
- **A PR records the why as well as the what.** It quotes the original ask, says what changed and says how it was tested. The template does the prompting. A PR is the written history of the repo, not a formality, and never a tool for blame.
- **Draft PRs are welcome.** Open them early and document as you go. Splitting one feature into several PRs is fine.
- **Merging:**
  - feature → dev: squash, so each PR is one commit, then delete the feature branch.
  - dev → main: merge commit. `dev` is never deleted.

## Commit often, never stash
- Commits are waypoints and push is the backup, so do both many times a day. If work is unfinished, make a WIP commit.
- `git stash` is never used. It's an invisible shared stack that loses work when more than one session works the same repo.
- Parallel work goes in **git worktrees**, one folder per branch, not in a shared checkout.
- Look at `git status` before every commit. Nothing gets added blindly, and secrets never enter the tree: real keys stay in gitignored files, and a committed `*.example` shows the shape.

## Quality is built in, not bolted on
- **Tests ship with the change.** New behaviour gets a test in the same PR, and a bug fix gets the test that would have caught it. Tests are living documentation, and the safety net grows with every bug.
- Built-in runners come first (Python `unittest`, Node `node:test`, `cargo test`), so a fresh clone can test with nothing extra installed.
- **CI runs the tests on every pull request.** A red check is fixed before merge, not after.
- **Every pull request is reviewed before it merges**, features and releases alike. Claude or Codex runs the code review and posts it on the PR as "Review by Claude" or "Review by Codex", matching the actual reviewer, so it's always clear an AI reviewed it. Real findings get fixed before merge, and anything risky goes to a human first. Whoever merges owns the result. A review is a conversation about the code, never about the person.

### How we test (JP Burford, week 5)
- **Unit tests** check one thing in isolation. They have no side effects (no database, network or files), run in milliseconds, and point straight at what broke. Pure logic lives in pure functions so it can be tested this way.
- **Dependency injection.** Code receives what it depends on (the database, settings, a clock, an HTTP client) as a parameter instead of creating it, so a test can hand it a fake.
- **Mock at the boundaries, not inside.** Fake the network, third-party services and I/O, never our own logic. Use real implementations for pure functions and utilities, and verify that a mock was called the way we expected. Too many mocks make tests that pass while the product is broken.
- **Only test our code.** We assume third-party libraries work, and we keep as few of them as we can: built-in runners and the standard library first, every dependency earning its place.
- **Integration tests** use real pieces working together (for example the real API on a throwaway local database). They create what they need and clean it up, even when they fail.
- **End-to-end tests** drive a real browser through a whole user journey. They give the most confidence and cost the most, so we keep them to the few journeys that matter.
- **Every bug gets the test that would have caught it**, and a test is only trusted once we've watched it fail.

## Plan in sprints
- Work lives on one GitHub Project board. Every card has a Priority (1 to 4), a Size (XS ≤4h, S 1 day, M 2–3 days, L 1 week, XL 1 sprint, XXL 2 sprints), a Why and a Due date.
- Sprints are two weeks long:
  - **Plan at the start:** fit the sprint to real capacity.
  - **Demo something that works at the end.**
  - **Retrospective:** what went well, what didn't, what changes next sprint.
- Schedule and people are fixed; scope is what gets negotiated.

## Working with people who aren't engineers (JP Burford, 27 Oct)
The job is not creating apps; it's solving problems for the people who rely on them.

- **Learn their world and speak their language.** Talk about outcomes, without jargon or hype.
- **Ask why before saying no.** Find the need behind a request. The solution isn't ours to own, so stay open to feedback and don't take it personally.
- **Sell the why, and back it with facts.** Treat other people's money like our own.
- **Don't overpromise.** Commit to what we can deliver, and negotiate scope in good faith.
- **Raise problems immediately, with a recommended fix.** Own mistakes openly, then learn from them.

Updates to partners, investors and collaborators follow one shape: the outcome, the evidence, where it stands against what we promised, problems with the fix we recommend, and what we need from them.

## Built to work anywhere
- No hardcoded home paths or usernames.
- Data lives in files or a database, never only in browser storage.
- Dependencies are declared in the README, and anything missing makes the tool degrade gracefully instead of crashing.
- Every repo is ready to publish from its first commit: README, `.gitignore`, LICENSE and sample data.
- **If something ever needs its own server** (JP Burford, 3 Nov), run it in a container built from a Dockerfile in the repo. Keep data outside the container, keep the database apart from the web server, and tag each image so a bad release can be rolled back. Don't add containers without a problem they solve.

## AI is the crew, not the author
- Claude Code writes much of the code here, inside the same process as everyone else: a branch, a PR with the why, tests and a review.
- AI makes mistakes, so its work is challenged and checked like anyone's.
- The person merging owns the result.

## Running the tests here

```bash
cargo test --workspace
```
