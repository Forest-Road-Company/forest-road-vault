# Corrovera dual-chain source ensemble

## How to read the claim count

The review produced 317 claims across 88 of 125 scoped source files. That number is not a count of
317 confirmed defects. Reviewers agreed on some claims, split on others, and two were explicitly
refuted in the original result. Both proposed High claims lacked consensus and were later refuted
after interacting dependencies were visible.

The report's headline table at publication recorded 35 two-reviewer Medium claims and 31 unresolved
Medium claims. Later correctness work consolidated duplicate mechanisms, restored the omitted
historical regression corpus, read the interacting contracts, and corrected the supported issues.
The findings list on this page records the material groups and current status; the full claim
corpus remains in the named report.

## Scope limit

Each file was reviewed alone. Dependency closure was explicitly not established, and deployment
scripts were outside scope. Sixty-eight claims named that limitation themselves. The round could
find local defects, but it could not clear cross-contract accounting, role topology, ceremony
validation or deployment behavior.

Later full-suite, dependency-aware, diff and deployed-address reviews supply evidence for the
areas they actually exercised. They do not retroactively expand this review's scope.

## High-severity candidates

Neither proposed High survived dependency-aware verification. The apparent ReserveCascade issue
depended on a value being counted by `backingValue()` that the interacting contract does not count.
The ClaimBridge candidate also failed once its sibling checks and actual call path were included.
The register preserves the proposed rating and marks the group superseded rather than pretending
the original readers agreed.
