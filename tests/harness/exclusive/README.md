# Exclusive harness suites

Place a suite here only when it cannot safely share the portable worker pool.
Explain the concrete constraint in a comment in the suite, and prefer isolating
its fixtures when practical. Bounded child workers alone do not require
exclusive execution.

These suites are discovered automatically and run one at a time after all
product and parallel harness suites finish. This directory currently contains
no suites; scheduler regression fixtures cover its execution contract.
