/-
  Tests for `Lode.Workspace`' pure parts: reading `git diff --raw`, the
  bodies of GitHub's tree entries and GitLab's commit actions, URLs, and the
  linen revision a manifest locks.
-/
import LodeTest.Util
import Lode.Workspace

open Lean (Json)
open Lode.Workspace

namespace LodeTests.Workspace

def nativeEntry (path mode : String) := Json.mkObj [("path", Json.str path), ("mode", Json.str mode)]
#guard (NativeFile.ofJson (nativeEntry "src/Main.lean" "100644")).toOption.isSome
#guard (NativeFile.ofJson (nativeEntry "bin/run" "100755")).toOption.isSome
#guard ["../outside", "src/../outside", "/outside", "a%2Fb", ".git/config", ".GIT/config", ".LaKe/cache"].all
  (fun path => (NativeFile.ofJson (nativeEntry path "100644")).toOption.isNone)
#guard (NativeFile.ofJson (nativeEntry "link" "120000")).toOption.isNone
#guard (NativeFile.ofJson (nativeEntry "submodule" "160000")).toOption.isNone

def raw : String :=
  ":000000 100644 0000000 1111111 A\x00lean/New.lean\x00" ++
  ":100644 100755 2222222 3333333 M\x00run.sh\x00" ++
  ":100644 000000 4444444 0000000 D\x00old file.txt\x00"

#guard parseRaw raw == #[
  { status := 'A', mode := "100644", blob := "1111111", path := "lean/New.lean" },
  { status := 'M', mode := "100755", blob := "3333333", path := "run.sh" },
  { status := 'D', mode := "000000", blob := "0000000", path := "old file.txt" }]
#guard parseRaw "" == #[]
#guard summarize (parseRaw raw) == "3 file(s): 1 added, 1 modified, 1 deleted"

-- GitHub: a deletion is a null sha on a blob entry.
#guard (githubTreeEntry (parseRaw raw)[2]! none).compress ==
  "{\"mode\":\"100644\",\"path\":\"old file.txt\",\"sha\":null,\"type\":\"blob\"}"
#guard (githubTreeEntry (parseRaw raw)[1]! (some "abc")).getObjValAs? String "mode" == .ok "100755"

-- GitLab: one action per change; executables keep their bit; no symlinks.
#guard ((gitlabAction (parseRaw raw)[0]! (some "Zm9v")).toOption.map (·.compress)) ==
  some "{\"action\":\"create\",\"content\":\"Zm9v\",\"encoding\":\"base64\",\"execute_filemode\":false,\"file_path\":\"lean/New.lean\"}"
#guard ((gitlabAction (parseRaw raw)[1]! (some "")).toOption.bind fun j => (j.getObjValAs? Bool "execute_filemode").toOption) == some true
#guard ((gitlabAction (parseRaw raw)[2]! none).toOption.map (·.compress)) ==
  some "{\"action\":\"delete\",\"file_path\":\"old file.txt\"}"
#guard (gitlabAction { status := 'A', mode := "120000", blob := "x", path := "link" } (some "")).toOption.isNone

-- URLs.
#guard percentEncode "a b/c~" == "a%20b%2Fc~"
#guard branchPath "feature/x y" == "feature/x%20y"
#guard githubBase { host := .github, segments := ["o", "r"], cloneUrl := "" } == .ok "https://api.github.com/repos/o/r"
#guard gitlabBase { host := .gitlab, segments := ["g", "p"], cloneUrl := "" } == "https://gitlab.com/api/v4/projects/g%2Fp"
#guard isCodeloadUrl "https://codeload.github.com/o/r/legacy.tar.gz/x" && !isCodeloadUrl "https://evil.com/"
#guard backend { host := .github, segments := [], cloneUrl := "" } true == .github
#guard backend { host := .github, segments := [], cloneUrl := "" } false == .git
#guard backend { host := .other "x.org", segments := [], cloneUrl := "" } true == .git

-- The linen revision a manifest locks (read with Lake's own parser).
def manifest (packages : String) : String :=
  "{\"version\": \"1.2.0\", \"packagesDir\": \".lake/packages\", \"name\": \"demo\", \"lakeDir\": \".lake\", \"packages\": [" ++
    packages ++ "]}"
def linenEntry (rev : String) : String :=
  "{\"url\": \"https://github.com/typednotes/linen\", \"type\": \"git\", \"subDir\": null, \"scope\": \"\", " ++
  "\"rev\": \"" ++ rev ++ "\", \"name\": \"linen\", \"manifestFile\": \"lake-manifest.json\", " ++
  "\"inputRev\": \"v1.5.0\", \"inherited\": false, \"configFile\": \"lakefile.lean\"}"

#guard linenRev? (manifest (linenEntry "743227ed26fca80dde2e66dc0d1eaba0fecb5a49")) ==
  some "743227ed26fca80dde2e66dc0d1eaba0fecb5a49"
#guard linenRev? (manifest (linenEntry "v1.5.0")) == none
#guard linenRev? (manifest "") == none
#guard linenRev? (manifest ("{\"type\": \"path\", \"name\": \"linen\", \"dir\": \"../linen\", \"scope\": \"\", " ++
  "\"manifestFile\": \"lake-manifest.json\", \"inherited\": false, \"configFile\": \"lakefile.lean\"}")) == none
#guard linenRev? "not json" == none

end LodeTests.Workspace
