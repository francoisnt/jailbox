# Recommendation: document floating development-image cache behavior

A floating `DEV_IMAGE` tag can remain cached when the wrapper image is rebuilt,
so an upstream tag update is not necessarily pulled automatically.

Document that users may need `--clean` to pick up a newer upstream image.
