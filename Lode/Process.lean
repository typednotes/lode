/-
  Lode.Process — the environments lode runs commands with

  Everything lode runs (`git`, `tar`, `lake`, the model's `bash` commands)
  goes through linen's `System.Process.run`: stdout and stderr captured,
  optional stdin, and a deadline and the session's abort flag after which
  the whole process group is killed (so `lake`'s `lean` workers and a shell's
  children go with it). What is lode's own is the environment: git with a
  fixed identity, and model-driven commands without lode's secrets.
-/
import Linen.System.Process

namespace Lode.Process

/-- The environment `git` and `lake` run with: linen's `hermeticGit` (the
    host's global and system git configuration ignored, git never prompting)
    and a fixed committer identity, since lode commits. -/
def hermeticGit : Array (String × Option String) :=
  System.Process.hermeticGit ++
  #[("GIT_AUTHOR_NAME", some "lode"), ("GIT_AUTHOR_EMAIL", some "lode@typednotes.org"),
    ("GIT_COMMITTER_NAME", some "lode"), ("GIT_COMMITTER_EMAIL", some "lode@typednotes.org")]

/-- lode's own configuration, removed from the environment of everything
    the model runs (`bash`, and `lake build`, which runs a project's
    lakefile): the API token, lun's token and a direct model key must not
    reach model-driven code. -/
def ownVariables : Array String :=
  #["LODE_TOKEN", "LODE_MODEL_API_KEY", "LODE_LUN_TOKEN", "LODE_LUN_URL", "LODE_LIAISON_URL",
    "LODE_MODEL_API", "LODE_MODEL_NAME", "LODE_MODEL_BASE_URL", "LODE_MODEL_MAX_TOKENS",
    "LODE_MODEL_CONTEXT_WINDOW", "LODE_WORKDIR", "LODE_PORT", "LODE_ALLOW_LOCAL"]

/-- The environment of model-driven commands: `hermeticGit`, without lode's
    own variables. -/
def toolEnv : Array (String × Option String) :=
  hermeticGit ++ ownVariables.map (·, none)

end Lode.Process
