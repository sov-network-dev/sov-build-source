# SOV build source

Build inputs for the SOV client and node. The workflows in `.github/workflows/`
compile them and publish artifacts to a separate releases repository.

`sov-builder.yml` is the tier-2 builder: any account may run it, it produces an
unsigned build, and it publishes a content digest so independent builders can be
compared. It never receives a signing key.
