#!/usr/bin/env python3
"""Real background checkout, retry identity and user-question pause/resume."""
import argparse,json,os,signal,socket,subprocess,tempfile,time,urllib.request,urllib.error,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser();p.add_argument("--temp-root",type=Path,required=True);p.add_argument("--checkout-delay",type=float,default=35);a=p.parse_args()
    out=Path(tempfile.mkdtemp(prefix="lode-automatic-",dir=a.temp_root));repo=out/"repo";repo.mkdir()
    def run(cmd,cwd=repo):return subprocess.run(cmd,cwd=cwd,check=True,capture_output=True,text=True).stdout.strip()
    (repo/"README.md").write_text("Automatic interaction fixture\n")
    run(["git","init","-q","-b","main"]);run(["git","add","README.md"]);run(["git","-c","user.name=Fixture","-c","user.email=fixture@example.invalid","-c","commit.gpgsign=false","commit","-qm","Fixture"])
    with socket.socket() as s:s.bind(("127.0.0.1",0));port=s.getsockname()[1]
    env={**os.environ,"LODE_PORT":str(port),"LODE_ALLOW_LOCAL":"1","LODE_TOKEN":"automatic-fixture","LODE_WORKDIR":str(out/"sessions")}
    git=shutil.which("git");assert git
    shim=out/"bin";shim.mkdir()
    (shim/"git").write_text("#!/usr/bin/env python3\nimport os,sys,time\nif 'clone' in sys.argv[1:]:time.sleep("+repr(a.checkout_delay)+")\nos.execv("+repr(git)+",["+repr(git)+"]+sys.argv[1:])\n")
    (shim/"git").chmod(0o755)
    env["PATH"]=str(shim)+os.pathsep+env.get("PATH","")
    for k in ["LODE_LIAISON_URL","LODE_MODEL_API_KEY","LODE_LUN_URL"]:env.pop(k,None)
    log=(out/"server.log").open("w");proc=subprocess.Popen([str(ROOT/".lake/build/bin/lode")],env=env,stdout=log,stderr=log,start_new_session=True)
    def api(path,body=None):
        r=urllib.request.Request(f"http://127.0.0.1:{port}"+path,None if body is None else json.dumps(body).encode(),{"Authorization":"Bearer automatic-fixture","Content-Type":"application/json"})
        try:
            with urllib.request.urlopen(r,timeout=20) as v:return v.status,json.load(v)
        except urllib.error.HTTPError as e:return e.code,json.load(e)
    try:
        for _ in range(100):
            try:api("/v0/sessions");break
            except OSError:time.sleep(.05)
        spec={"source":{"url":repo.as_uri(),"branch":"main"},"background":True,"requestKey":"same-immutable-request","model":{"api":"scripted","script":[
            {"calls":[{"name":"ask_user","arguments":{"text":"How should prices be rounded?","options":["up","down"],"freeText":False}},{"name":"write","arguments":{"path":"must-not-exist.txt","content":"unsafe continuation"}}]},
            {"calls":[{"name":"write","arguments":{"path":"after-answer.txt","content":"confirmed"}}]}, {"text":"Done"}]}}
        start=time.monotonic();code,created=api("/v0/sessions",spec);assert code==201 and created["backgroundCheckout"],created
        assert time.monotonic()-start<2,"session creation waited for checkout"
        sid=created["id"];code,retry=api("/v0/sessions",spec);assert code==201 and retry["id"]==sid,retry
        changed={**spec,"source":{**spec["source"],"path":"other"}};code,refused=api("/v0/sessions",changed);assert code>=400,refused
        def wait(state):
            for _ in range(1600):
                _,v=api("/v0/sessions/"+sid)
                if v["state"]==state:return v
                time.sleep(.05)
            raise AssertionError(v)
        assert api("/v0/sessions/"+sid)[1]["state"]=="opening"
        wait("idle")
        assert api(f"/v0/sessions/{sid}/messages",{"text":"Generate the fixture","messageKey":"first-intent"})[0]==202
        waiting=wait("waiting");q=waiting["question"];checkout=out/"sessions/sessions"/sid/"checkout"
        assert not (checkout/"must-not-exist.txt").exists()
        assert api(f"/v0/sessions/{sid}/answer",{"id":q["id"],"answer":"invented"})[0]==409
        assert api(f"/v0/sessions/{sid}/answer",{"id":q["id"],"answer":"up"})[0]==202
        final=wait("idle");assert final["question"] is None and (checkout/"after-answer.txt").read_text()=="confirmed"
        assert api(f"/v0/sessions/{sid}/answer",{"id":q["id"],"answer":"down"})[0]==409
        before=final["entries"];api(f"/v0/sessions/{sid}/messages",{"text":"Generate the fixture","messageKey":"first-intent"});time.sleep(.1)
        assert api(f"/v0/sessions/{sid}")[1]["entries"]==before
        print("PASS: real background creation, immutable retry identity, typed question pause, blocked following effects, validated answer/resume and duplicate-intent suppression")
        print("PASS: session creation returns while real git checkout exceeds the app's 30-second RPC deadline")
        spec={**spec,"requestKey":"cancel-question","model":{"api":"scripted","script":[{"calls":[{"name":"ask_user","arguments":{"text":"Continue?","options":["yes"],"freeText":False}}]},{"calls":[{"name":"write","arguments":{"path":"after-cancel.txt","content":"must not execute"}}]}]}}
        code,created=api("/v0/sessions",spec);assert code==201
        sid=created["id"];wait("idle")
        api(f"/v0/sessions/{sid}/messages",{"text":"Ask then wait"});q=wait("waiting")["question"]
        assert api(f"/v0/sessions/{sid}/abort",{})[0]==202
        assert api(f"/v0/sessions/{sid}/answer",{"id":q["id"],"answer":"yes"})[0]==409
        assert not (out/"sessions/sessions"/sid/"checkout/after-cancel.txt").exists()
        print("PASS: cancelling a pending question retires the answer and prevents continuation effects")
    finally:
        os.killpg(proc.pid,signal.SIGTERM);proc.wait(timeout=10);log.close()
    print("Artifacts:",out)
if __name__=="__main__":main()
