# AWS issuance and downstream authority boundary

Inspected `master` at `fde073cba7002f7e9b28ec8714f9b31ce76868d9` on 2026-10-09.
See PADE `docs/security/2026-10-boundary-investigation.md` for the cross-repository
threat model and assertion-replay tests. No production state was inspected or changed.

## Verified from source and local fixtures

`providers/aws-s3/main.go` accepts broker-verified Google issuer context, then
`federation.go` mints **Cloud Run runtime** identity and requests STS credentials
for the operator-configured role, for 900 seconds. It does not use the caller's
JWT, choose a role or prefix by caller, send a caller session tag, or pass an STS
session policy. The provider trusts invocation by the broker; it is not an
independent caller JWT verifier or subject allowlist.

Two subjects authorized by the broker for the same binding receive equivalent
role authority. New `TestDistinctAuthorizedCallersUseSameRuntimeAuthority` proves
that distinct verified subjects, with no raw JWT, both use the same synthetic
runtime token and configured role/bucket/prefix. Fake STS checks the role, runtime
assertion, requested duration, and absence of a session policy. This is not a live
AWS issuance or IAM authorization test.

`TestDeniedCallerDoesNotContactMetadataOrSTS` verifies missing/non-Google/mismatched
issuer context fails before either fake service is called. Existing rendered
configuration tests keep AWS out of Cursor rules and include it only for the
configured Google subject. PADE's signed-JWT tests independently verify broker
subject/capability denial and that replay cannot bypass authorization.

## What actually limits a credential

`AWS_S3_BUCKET` and `AWS_S3_PREFIX` are application configuration, **not** security
controls. A child can change them. AWS authorization must deny requests outside
the role's intended resource scope even when those environment values change.
The rendering contract in `scripts/test-aws-s3-policy-contract.sh` asserts:

- exactly `s3:PutObject` on `arn:aws:s3:::<configured-bucket>/experiment-007/*`;
- exact Google runtime `sub`/`aud` mapping and federation audience;
- no wildcard actions, other resources, or other trust statements;
- unsafe bucket/audience/empty subject inputs are rejected.

Bootstrap source refuses unexpected attached/inline policies, refuses an unrelated
existing trust relationship, and verifies the policy written. These properties
are sufficient for the **intended shared scope** only if actual IAM and resource
policies match and no other path broadens it. Tests validate generated documents,
not AWS policy evaluation. Do not treat their success as attesting production.

The common prefix permits callers to overwrite one another's keys. If callers
need separate authority, use deployment-owned roles, separate resource prefixes,
or an IAM-enforced session-policy/tag design, with negative tests for that actual
configuration. Merely forwarding the caller JWT, logging its subject, or changing
environment hints does not provide isolation. No PADE core IAM mapping is needed.

## Residual replay and ingress risk

A captured accepted caller JWT can request new STS issuance until token acceptance
or broker policy ends. It cannot request a capability outside broker policy.
Downstream credentials may outlive the caller assertion. The deploy script sets
32 in-flight resolves per process, 25-second resolution timeout, three maximum
Cloud Run instances, public ingress and no platform invoker IAM check. This is
not a distributed per-subject rate limit. No such ingress rule is configured in
this repository. Broker auth remains required; use a staging experiment to
choose issuance budgets if abuse risk warrants them.

WIF providers for Vercel/Sanity genuinely need the raw caller JWT for STS subject
exchange; AWS, shared static material, and GitHub/Google reference providers do
not. Keeping raw forwarding for compatibility does not imply AWS needs it.
An optional attributes-only exec mode is proposed in the main report, not deployed.

## Tests and compatibility

Run `make test-providers test-config-contract`. Both pass locally using fake
services and synthetic identifiers. The policy contract is included in the
existing CI target and requires Bash and jq (already used by deployment tooling).
Existing Go fixtures no longer print material on two AWS assertion failures.
There are no runtime provider, IAM, deployment image/pin, or protocol changes.

## Future live verification prerequisites

Use an explicitly authorized disposable role/bucket and isolated broker identities;
review role policies, bucket policies, permission boundaries, organization policy,
and alternate direct-federation paths (including the separate Experiment 007
Phase 2 role). Record allowed-prefix PutObject success, outside-prefix/bucket and
Get/Delete/List denial, and intended cross-subject behavior. Repeated issuance
must not change the role's authority. Keep credentials only in memory; capture
safe status codes and resource identifiers, not tokens. No live check was run here.
