import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLANNER = ROOT / "scripts" / "jev_codex_planner.py"
SPEC = importlib.util.spec_from_file_location("jev_codex_planner", PLANNER)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

FAKE = r'''#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path
args=sys.argv[1:]; prompt=sys.stdin.read()
Path(os.environ["FAKE_CAPTURE"]).write_text(json.dumps({"args":args,"prompt":prompt}))
mode=os.environ.get("FAKE_MODE","success")
if mode in ("sleep","ignore_term"):
    if mode=="ignore_term": signal.signal(signal.SIGTERM, signal.SIG_IGN)
    Path(os.environ["FAKE_PID"]).write_text(str(os.getpid())); time.sleep(30)
response=json.loads(os.environ["FAKE_RESPONSE"])
Path(args[args.index("--output-last-message")+1]).write_text(json.dumps(response))
print(json.dumps({"type":"thread.started","thread_id":"fake"})); print(json.dumps({"type":"turn.started"}))
item={"id":"message","type":"agent_message","text":json.dumps(response)}
if mode=="tool": item={"id":"tool","type":"command_execution","command":"pwd"}
print(json.dumps({"type":"item.completed","item":item})); print(json.dumps({"type":"turn.completed"}))
print("fake diagnostic",file=sys.stderr)
'''

class PlannerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.dir=Path(self.temp.name)
        self.fake=self.dir/"codex"; self.fake.write_text(FAKE); self.fake.chmod(self.fake.stat().st_mode|stat.S_IXUSR)
        self.capture=self.dir/"capture.json"; self.trace=self.dir/"traces"
        self.request={
            "protocol_version":2,"goal":"Update the requested item.",
            "state":{"foregroundApp":"Example","documentTitle":"Items","elements":[
                {"id":"owner-1","role":"group","label":"Item","value":"current","context":"List"},
                {"id":"owner-2","role":"group","label":"Other","value":"borrowed","context":"List"}],
                "observedProgress":{"controlMemory":{"owners":[
                    {"scope":{"app":"Example","document":"Items","owner":"Item","context":"List > Item"},
                     "previouslyObservedValues":["old","current","next"]},
                    {"scope":{"app":"Example","document":"Items","owner":"Other","context":"List > Other"},
                     "previouslyObservedValues":["borrowed"]}]}}},
            "observation_id":"observation-7","offered_actions":[{
                "operation":"perform_named_action","target_key":"e1","description":"Move next",
                "owner_id":"owner-1","owner_value":"current"}],
            "max_native_actions":1,"previous_subgoal":"Open item"}

    def tearDown(self): self.temp.cleanup()

    def response(self,**changes):
        value={"status":"continue","subgoal":"Inspect next","reason":"More evidence is needed",
            "observation_id":"observation-7","steps":[{"operation":"perform_named_action","target_key":"e1",
            "expected_value":"current","after_value":None,"inspection":True,"subgoal":"Move once"}]}
        value.update(changes); return value

    def run_planner(self,request=None,response=None,mode="success",effort="medium"):
        env=dict(os.environ); env.update({"JEV_CODEX_BINARY":str(self.fake),"JEV_TRACE_DIR":str(self.trace),
            "JEV_PLANNER_MODEL":"planner-test-model","JEV_PLANNER_REASONING_EFFORT":effort,
            "FAKE_CAPTURE":str(self.capture),"FAKE_MODE":mode,"FAKE_PID":str(self.dir/"pid"),
            "FAKE_RESPONSE":json.dumps(response or self.response())})
        raw=json.dumps(request or self.request,separators=(",",":"))
        return subprocess.run([sys.executable,str(PLANNER)],input=raw,text=True,stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,env=env,timeout=5),raw

    def test_success_cli_schema_prompt_and_monotonic_timing(self):
        result,raw=self.run_planner(); self.assertEqual(result.returncode,0,result.stdout); self.assertEqual(json.loads(result.stdout),self.response())
        capture=json.loads(self.capture.read_text()); args=capture["args"]
        for flag in ["--ignore-user-config","--ephemeral","--skip-git-repo-check","--json"]: self.assertIn(flag,args)
        self.assertEqual(args[args.index("--sandbox")+1],"read-only")
        self.assertEqual(args[args.index("--model")+1],"planner-test-model")
        configs=[args[i+1] for i,v in enumerate(args) if v=="--config"]
        self.assertIn('model_reasoning_effort="medium"',configs); self.assertIn('web_search="disabled"',configs)
        self.assertIn("End the route at the first unknown transition",capture["prompt"])
        call=next(self.trace.glob("planner-call-*")); self.assertEqual((call/"input.json").read_text(),raw)
        schema=json.loads((call/"schema.json").read_text()); self.assertEqual(set(schema["required"]),MODULE.RESPONSE_KEYS)
        self.assertEqual(set(schema["properties"]["steps"]["items"]["required"]),MODULE.STEP_KEYS)
        timing=json.loads((call/"timing.json").read_text())
        self.assertEqual(timing["duration_ns"],timing["ended_monotonic_ns"]-timing["started_monotonic_ns"])

    def test_tool_event_fails_closed(self):
        result,_=self.run_planner(mode="tool"); self.assertNotEqual(result.returncode,0)
        self.assertEqual(set(json.loads(result.stdout)),MODULE.RESPONSE_KEYS)
        self.assertIn("command_execution",next(self.trace.glob("planner-call-*/events.jsonl")).read_text())

    def test_request_and_effort_validation(self):
        for request in [dict(self.request,protocol_version=1),dict(self.request,max_native_actions=7),
            dict(self.request,offered_actions=[{"operation":"x"}])]:
            result,_=self.run_planner(request=request); self.assertNotEqual(result.returncode,0)
        result,_=self.run_planner(effort="ultra"); self.assertNotEqual(result.returncode,0)

    def test_exact_observation_action_and_current_value_binding(self):
        bad=[self.response(observation_id="old"),
            self.response(steps=[dict(self.response()["steps"][0],target_key="invented")]),
            self.response(steps=[dict(self.response()["steps"][0],expected_value="old")]),self.response(extra=True)]
        for response in bad:
            result,_=self.run_planner(response=response); self.assertNotEqual(result.returncode,0)

    def test_route_is_same_owner_inspection_with_known_value_chain(self):
        request=dict(self.request,max_native_actions=3)
        first=dict(self.response()["steps"][0],after_value="next")
        second=dict(first,expected_value="next",after_value=None,subgoal="Move again")
        result,_=self.run_planner(request=request,response=self.response(steps=[first,second])); self.assertEqual(result.returncode,0,result.stdout)
        bad=[self.response(steps=[dict(first,after_value=None),second]),
            self.response(steps=[first,dict(second,expected_value="old")]),
            self.response(steps=[dict(first,after_value="unknown"),dict(second,expected_value="unknown")]),
            self.response(steps=[dict(first,after_value="borrowed"),dict(second,expected_value="borrowed")]),
            self.response(steps=[dict(first,inspection=False),second])]
        for response in bad:
            result,_=self.run_planner(request=request,response=response); self.assertNotEqual(result.returncode,0)

    def test_terminal_steps_and_output_newline_limit(self):
        terminal=self.response(status="complete",subgoal="",reason="Observed complete",steps=[])
        result,_=self.run_planner(response=terminal); self.assertEqual(result.returncode,0,result.stdout)
        result,_=self.run_planner(response=self.response(status="blocked",subgoal="")); self.assertNotEqual(result.returncode,0)
        value=dict(terminal,reason=""); base=len(MODULE.protocol_bytes(value)); value["reason"]="x"*(MODULE.MAX_RESPONSE_BYTES-base)
        self.assertEqual(len(MODULE.protocol_bytes(value)),MODULE.MAX_RESPONSE_BYTES); MODULE.validate_response(value,self.request)
        value["reason"]+="x"
        with self.assertRaises(MODULE.PlannerError): MODULE.validate_response(value,self.request)

    def test_sigterm_kills_owned_process_group(self):
        env=dict(os.environ); env.update({"JEV_CODEX_BINARY":str(self.fake),"JEV_TRACE_DIR":str(self.trace),
            "FAKE_CAPTURE":str(self.capture),"FAKE_MODE":"ignore_term","FAKE_PID":str(self.dir/"pid"),
            "FAKE_RESPONSE":json.dumps(self.response())})
        process=subprocess.Popen([sys.executable,str(PLANNER)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
        process.stdin.write(json.dumps(self.request)); process.stdin.close(); deadline=time.monotonic()+3
        while not (self.dir/"pid").exists() and time.monotonic()<deadline: time.sleep(.02)
        child=int((self.dir/"pid").read_text()); started=time.monotonic(); process.send_signal(signal.SIGTERM); process.wait(timeout=5)
        self.assertLess(time.monotonic()-started,1); self.assertNotEqual(process.returncode,0)
        process.stdout.close(); process.stderr.close()
        with self.assertRaises(ProcessLookupError): os.kill(child,0)

if __name__=="__main__": unittest.main()
