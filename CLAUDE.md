@AGENTS.md

# Instructions for Claude

## Contributions to upstream projects

When preparing a contribution to an upstream project (enjoy-digital, litex-hub, m-labs, ...), never
link to or mention the owner's own repositories (`github.com/ohault/...`, including this one and the
forks), in files, commit messages or pull request descriptions. Use relative links or links to the
upstream project only. Before pushing a branch meant for an upstream pull request, search its files
and its commits (contents and messages) for `github.com/ohault` and for this project's name, and fix
any hit by rewriting the branch's commits, not with a fix commit on top.

Create such branches from the upstream default branch, never from a fork's default branch.
