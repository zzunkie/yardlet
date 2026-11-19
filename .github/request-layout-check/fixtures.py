from pathlib import Path
import sqlite3, uuid, json, time, zipfile, re
import os
from tempfile import TemporaryDirectory
qa=Path(os.environ["QA_ROOT"])
schema=Path("Sources/NativeHarnessClient/Store/SessionRepository.swift").read_text(encoding="utf-8").split('CREATE TABLE IF NOT EXISTS sessions (',1)[1].split(');',1)[0]
def uid(): return str(uuid.uuid4()).upper()
def entry(kind, **value): return dict(id=uid(),createdAt=800000000,content={kind:value})
def ask(req, status="pending"): return entry("permission",_0=req,state=status)
def words(key, *args): return dict(key=key,isVerbatim=False,args=list(args))
def opt(id, label, decision, scope=None): return dict(id=id,label=label,decision=decision,kind=id,**({"labelText":scope} if scope else {}))
actions=[opt("deny","Deny","deny"),opt("allow_session","Allow for session","allow",words("Allow for session")),opt("allow_always","Always allow in this project","allow",words("Always allow in this project (saved to %@)",words(".claude/settings.local.json"))),opt("allow_once","Allow","allow")]
kr="작업을 시작하기 전에 변경 사항을 확인하고 필요한 내용을 정리해 주세요. 다음 단계에서는 사용자가 입력한 문장을 자연스럽게 표시합니다."
def command(id, text="git status", label="Review the workspace changes"):
    return dict(id=id,title="Bash",detail=label,command=text,actions=actions,preview=dict(command={"_0":dict(text=text,omittedLineCount=0),"description":label}))
question=dict(id='question',title='AskUserQuestion',actions=[],structured={"questions":{"_0":[dict(question="어떤 검사를 먼저 실행할까요?",options=[dict(label="단위 검사",description="변경한 코드부터 확인합니다."),dict(label="통합 검사",description="전체 흐름을 확인합니다.")],allowsMultipleSelections=False,allowsCustomAnswer=True)]}})
user=entry("user",text=kr)
history=[entry("user",text="Fixture history %03d"%n) for n in range(300)]
testroot=str(qa)
rows=[
 ("QA Empty","ready",[],{}),
 ("QA Stacked","ready",history+[user,ask(command("run","\n".join("git status --short" for _ in range(25)))),ask(command("second")),ask(question)],{}),
 ("QA Scope","ready",[user,ask(command("run"))],{}),
 ("QA Question","ready",[user,ask(question)],{}),
 ("QA Answered","completed",[user,ask(command("denied"),"denied"),entry("assistant",text=kr,isStreaming=False)],{}),
 ("QA Failed","failed",[user,entry("activity",_0=dict(id="qa-failed-edit",kind="Edit",title="README.md",input="README.md",outcome="failed",output="Text not found"),state="failed"),entry("error",message="Fixture failed",recoverable=False)],{}),
 ("QA Korean","ready",[user,entry("assistant",text=("기록을 검토합니다. "+kr+" ")*3,isStreaming=False)],{"model":"claude-opus-4-7[1m]"}),
]
with TemporaryDirectory(dir=qa) as tmp:
    root=Path(tmp)/"Yardlet"; tr=root/"transcripts";tr.mkdir(parents=True)
    db=sqlite3.connect(root/"session-index.sqlite3")
    db.execute("CREATE TABLE sessions ("+schema+")")
    for n,(title,status,rows_,options) in enumerate(rows):
        sid=uid()
        now=time.time()-n*2
        db.execute("INSERT INTO sessions (id,harness,workspace_path,runtime_path,title,status,created_at,updated_at,title_origin,provider_options) VALUES (?,?,?,?,?,?,?,?,?,?)",(sid,"claude-code",testroot+r"\workspace",testroot+r"\mock\claude.exe",title,status,now,now,"manual",json.dumps(options)))
        (tr/(sid+".json")).write_text(json.dumps(rows_,ensure_ascii=False),encoding="utf-8")
    db.commit();db.close()
    with zipfile.ZipFile(qa/"fixtures.zip","w",compression=zipfile.ZIP_DEFLATED) as z:
        for p in root.rglob("*"):
            if p.is_file(): z.write(p,p.relative_to(root.parent))
