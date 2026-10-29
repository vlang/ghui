# Repository instructions

Before creating any commit, and after implementing a feature, always run `make app`.
Resolve build failures before committing or reporting the feature as complete.

`make app` builds the production executable (`v -prod -o ghui .`) with the
repository-local ui2 compatibility patch and module search path prepared, then
packages it as `Github.app`. To build only the executable, use `make prod`.
