# Build a Linen cell locally with Codex

Run from the Lode checkout with Git, `jq` and a running Podman or Docker
engine. The script builds the Lode image with Linen 4.1, seeds a bare Git
repository inside the container and runs Lode against it.

## Rehearse with a scripted model

```sh
Examples/cell-addition/run-container.sh
# With Docker
Examples/cell-addition/run-container.sh --engine docker
```

The scripted run exercises the real edit, Lean build, Git publication, and
worker calls locally. The first image build needs access to its dependency
repositories. Use `--image IMAGE` to reuse a local Lode image built from this
checkout. Each step reports its result in color on a terminal. Set `NO_COLOR=1`
for plain output.

## Run with Codex

Set `OPENAI_API_KEY` in your shell. The live run uses GPT-6.2 Sol via the
OpenAI Responses API. Pass `--yes` to confirm paid inference non-interactively.
[Codex models](https://developers.openai.com/codex/models) ·
[OpenAI API quickstart](https://developers.openai.com/api/docs/quickstart).

```sh
Examples/cell-addition/run-container.sh --live
# With Docker and a known local image
Examples/cell-addition/run-container.sh --engine docker --image localhost/lode:cell-demo --live --yes
```

Lode asks the model to implement and prove an effect-free addition function
against Linen's typed contract. It publishes the source to the container's bare Git
repository, exports the compiled worker and calls it with three input pairs.
The first case checks that `2 + 3 = 5`.

## Inspect the result

The script prints a directory under the host's `/tmp`. It contains
`project.git`, the compiled `add-worker`, the output receipt and logs. Use
`--output NEW_DIR` to choose the directory. Copying out the repository works
when the container runs in a VM with a separate filesystem. The worker is a
Linux executable for the image's architecture.

```sh
work=/tmp/lode-cell-container.REPLACE_ME
git --git-dir="$work/project.git" log -1 --format='%H %s' main
git --git-dir="$work/project.git" show main:LocalCell/Worker.lean
cat "$work/calls.jsonl"
```

For a signed Linen cell package, use the exported worker and the compiler's
build record and signing key. [Signed cell output](cell-output.md).
