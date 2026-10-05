"""Small synchronous Lode HTTP client; only Python's standard library is needed.

Import ``Client`` from this module in your own scripts. Raw requests retain the
HTTP status in a Lun-example-style {status, body} envelope; session helpers raise
ApiError for HTTP failures. Run failures and user questions remain log/status
data, so callers can decide whether to repair, answer, abort or resume.
"""
import json
import time
import urllib.error
import urllib.parse
import urllib.request


class ApiError(RuntimeError):
    """An HTTP refusal, with the original status and decoded response body."""

    def __init__(self, response):
        self.status = response["status"]
        self.body = response["body"]
        detail = self.body.get("error", self.body) if isinstance(self.body, dict) else self.body
        super().__init__(f"HTTP {self.status}: {detail}")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # An API redirect must not forward the caller's bearer token elsewhere.
        return None


class Client:
    """Connect to an existing service without owning its process or its sessions."""

    def __init__(self, base_url, token=None, timeout: float = 120):
        url = urllib.parse.urlsplit(base_url)
        if (url.scheme not in ("http", "https") or not url.hostname
                or url.username is not None or url.password is not None
                or url.query or url.fragment):
            raise ValueError("base_url must be an HTTP(S) service URL without credentials/query/fragment")
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self._opener = urllib.request.build_opener(_NoRedirect())

    def request(self, method, path, body=None, *, timeout=None):
        """Return {status, body}; JSON, plain-text diff and empty health all work.

        Transport errors propagate. Requests are never automatically retried:
        choose requestKey/messageKey explicitly when retrying supported intents.
        """
        if not path.startswith("/") or path.startswith("//") or "#" in path:
            raise ValueError("path must be an API path beginning with one slash")
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if self.token is not None:
            headers["Authorization"] = "Bearer " + self.token
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            response = self._opener.open(request, timeout=self.timeout if timeout is None else timeout)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            text = response.read().decode("utf-8")
            content = json.loads(text) if text and response.headers.get_content_type() == "application/json" else text
            return {"status": response.status, "body": content}

    def _body(self, method, path, body=None, **options):
        response = self.request(method, path, body, **options)
        if not 200 <= response["status"] < 300:
            raise ApiError(response)
        return response["body"]

    @staticmethod
    def _session(session_id, suffix=""):
        return "/v0/sessions/" + urllib.parse.quote(session_id, safe="") + suffix

    def create(self, spec):
        """Forward a session spec, including optional model/tools/contracts/keys."""
        return self._body("POST", "/v0/sessions", spec)

    def sessions(self):
        return self._body("GET", "/v0/sessions")["sessions"]

    def status(self, session_id, *, timeout=None):
        return self._body("GET", self._session(session_id), timeout=timeout)

    def send(self, session_id, text, **fields):
        """Start or steer work; extra fields are the server's message-request fields."""
        return self._body("POST", self._session(session_id, "/messages"), {**fields, "text": text})

    def messages(self, session_id, *, after=0, wait=0, timeout=None):
        """Read from an entry-index cursor; next is the next cursor, not a byte offset."""
        if type(after) is not int or after < 0 or type(wait) is not int or not 0 <= wait <= 60:
            raise ValueError("after must be a nonnegative integer and wait an integer from 0 to 60")
        query = urllib.parse.urlencode({"after": after, "wait": wait})
        return self._body("GET", self._session(session_id, "/messages?") + query,
                          timeout=max(self.timeout, wait + 5) if timeout is None else timeout)

    def follow(self, session_id, *, after=0, timeout: float = 3600, wait=10):
        """Yield log entries until idle, failed or waiting for a user answer.

        Background checkout is followed even when running is initially false.
        Timeout bounds this client wait; it does not abort work on the server.
        After answering or submitting another task, follow again from the saved
        cursor. A run_finished event does not imply every tool succeeded.
        """
        if timeout <= 0 or type(wait) is not int or not 0 <= wait <= 60:
            raise ValueError("timeout must be positive and wait an integer from 0 to 60")
        deadline = time.monotonic() + timeout

        def remaining():
            seconds = deadline - time.monotonic()
            if seconds <= 0:
                raise TimeoutError("Lode session did not stop before the client deadline")
            return seconds

        while True:
            page = self.messages(session_id, after=after, wait=min(wait, max(0, int(remaining() - 1))),
                                 timeout=min(remaining(), max(self.timeout, wait + 5)))
            yield from page["entries"]
            after = page["next"]
            if not page["running"]:
                status = self.status(session_id, timeout=min(self.timeout, remaining()))
                # Log and running are separate snapshots in the HTTP reply. A
                # terminal event can be appended between them; drain it first.
                if status.get("entries", after) > after:
                    continue
                if status["state"] not in ("opening", "running"):
                    return
            if not page["entries"]:
                time.sleep(min(0.1, remaining()))

    def abort(self, session_id):
        return self._body("POST", self._session(session_id, "/abort"), {})

    def answer(self, session_id, question_id, answer):
        return self._body("POST", self._session(session_id, "/answer"), {"id": question_id, "answer": answer})

    def credentials(self, session_id, credentials):
        """Forward fresh caller-issued credentials; the client does not mint warrants."""
        return self._body("PUT", self._session(session_id, "/credentials"), credentials)

    def diff(self, session_id):
        return self._body("GET", self._session(session_id, "/diff"))

    def delete(self, session_id):
        return self._body("DELETE", self._session(session_id))
