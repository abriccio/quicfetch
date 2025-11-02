quick repo for making a web library thing in Zig

Not even remotely portable or generic. My use-cases only.

## Notes for changes:

* Let's work with the concept that the only logging buffer should be the user's
message buffer, except for debug messages printed to stdout. Don't duplicate
error messages to stderr.
