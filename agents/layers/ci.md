<!-- relentless:owned -->
# Layer: ci

Read this when `layers.ci` is true.

Bootstrap writes `.github/workflows/relentless-ci.yml` only while this layer is on and the repo does not already have that workflow. An existing workflow stays as the repo wrote it. An install from before the `layers` key does not recreate a workflow the repo removed.
