# SOV build source

Build inputs for the SOV client and node. The workflows in `.github/workflows/`
compile them and publish artifacts to a separate releases repository.

`sov-builder.yml` is the tier-2 builder: any account may run it, it produces an
unsigned build, and it publishes a content digest so independent builders can be
compared. It never receives a signing key.

## What this repository is

The source the SOV client and node are built from, and the workflows that build them.
Anyone can read it, build it, and compare what they get against what the network
publishes — that comparison is the point.

A release is signed with a key this repository does not contain. The signing key lives in
the release account's secrets; tier-2 builders receive no key at all and publish only a
content digest, so two independent builds of the same commit can be checked against each
other. See `.github/workflows/`.

The published binaries, their checksums and the signed distribution manifest live in the
releases repository. The app verifies that manifest's signature before it will update
itself, so trust rests on the signature rather than on any host.

## History

This repository was squashed to a single commit before it was made public: earlier commits
carried build-tool crash logs containing the absolute paths of the machine that produced
them. Nothing else was removed, and the content is unchanged. Releases are verified by
their checksums and the signed manifest, not by a build commit id.
