<!-- relentless:owned -->
# Layer: githooks

Read this when `layers.githooks` is true.

`.relentless/githooks/pre-commit` and `pre-push` refuse commits and pushes on main or master, and non-fast-forward pushes. They do nothing when this layer is off. A fresh bootstrap leaves the layer off. A config with no `layers` key keeps the 1.4.11 hooks.
