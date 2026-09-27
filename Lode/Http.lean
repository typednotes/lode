/-
  Lode.Http — one HTTP request, over linen's client

  For the calls lode makes itself: liaison's egress, lun's API, a directly
  configured model endpoint (development), and GitHub's short-lived signed
  tarball URL (as lun fetches it). The answer is linen's own
  `Network.HTTP.Client.Response`.
-/
import Linen.Network.HTTP.Simple

namespace Lode.Http

open Network.HTTP.Types
open Network.HTTP.Client (Response)

/-- Make one request to a runtime URL. `timeoutMs` bounds each socket read and
    write. -/
def request (method : StdMethod) (url : String) (headers : List (String × String) := [])
    (body : Option String := none) (timeoutMs : Nat := 60000) : IO Response := do
  let req ← Network.HTTP.Simple.parseUrl! url
  Network.HTTP.Simple.httpBS { req with
    method := Method.standard method
    headers := headers.map fun (k, v) => (Data.CI.mk' k, v)
    body := body.map String.toUTF8
    timeoutMillis := timeoutMs }

/-- The status code of an answer. -/
def status (r : Response) : Nat := r.statusCode.statusCode

/-- The body of an answer as text (empty if it is not UTF-8). -/
def text (r : Response) : String := (String.fromUTF8? r.body).getD ""

end Lode.Http
