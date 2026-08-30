# Monorepo implementation coordination notes

These clarifications were agreed between the coordinating, tool,
and migration agents under the prompt's coordination rule. They are local
implementation notes, not changes to the original prompt.

1. The specified POSIX plan renderer is sequential, while the executor supports
   parallel package execution. Preserve the specified renderer. Exact execution
   order and fail-fast equivalence apply at concurrency 1. With higher
   concurrency, print a notice that shell replay serializes the same steps and
   therefore changes scheduling and which already-started steps can finish after
   failure. Preserve each step's argv, cwd, environment, and accepted exit codes.
   Document this limitation and test sequential plan/executor equivalence.
   The specified fail-fast `set -e` script also returns the failing child's
   status, while the CLI normalizes step failures to 1 and startup errors to 2.
   Preserve that explicit renderer and document the outer-status distinction;
   parity tests compare executed steps, child statuses, and success/failure.
2. ManyMatrix's codegen/clean script bodies use raw per-member commands. Document
   optional `monorepo exec` equivalents separately. This resolves the table's
   helper-invoking scripts in favor of the principle that no repository depends
   on installing the helper.
3. Zero state means the orchestrator does not create repository configuration,
   caches, or resolution state. Explicitly launched Dart/Flutter commands can
   have their own documented effects. Workspace discovery is the required
   read-only metadata subprocess; `check` never executes inspected workflow or
   configured script bodies.

4. The ManyType root lockfile is currently untracked. Preserve its original
   content and checkout. The migration compares freshly generated isolated
   before/after lockfiles and retains that evidence outside the repository.
   Preserve the repository's existing no-tracked-lock policy rather than adding
   an entirely new lockfile that cannot satisfy the pure-deletion Git diff rule.
   This exception was agreed with the migration agent before B3.
