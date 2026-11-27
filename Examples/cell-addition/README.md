# Generate and use an addition cell

Use the container walkthrough to build and call a Linen worker with Podman
or Docker. It supports both scripted and live Codex runs.
[Container guide](../../docs/local-cell-with-codex.md).

```sh
lake build lode
python3 Examples/cell-addition/test.py
```

The script starts with a temporary Git repository. Lode's scripted model
generates `Cell/Contract.lean`, `Cell/Addition.lean`, and `Main.lean` through
the same write, check and publish tools used by ordinary sessions. The
contract has two `Nat` inputs, a `Nat` result and a Linen `Eff []` row.
Lean checks a theorem that running the cell returns the sum for every pair
of inputs. A fresh clone builds the cell's native static library and the
consumer executable. The test creates and verifies a manifest for the library,
then runs the executable with three input pairs.

Use `--output output/cell-addition` to keep the generated sources, library and
manifest. The Lake configuration refers to the local Linen checkout, and the
manifest records the temporary Git repository used to build the example. The
consumer imports the cell at compile time. See the [cell package design](../../docs/architecture/lode.md#cell-sources-and-native-packages).
