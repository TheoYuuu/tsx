#!/usr/bin/env python3
"""Generated fixtures only; each round has independent evidence and runtime paths."""
import copy,hashlib,http.server,json,os,socket,subprocess,threading,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parent
BIN=ROOT/'target/debug/lumax-codex-translation-prototype'


def sandbox(run,port):
 return '''(version 1)
(deny default)
(allow file-read-metadata)
(allow file-read* (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share") (subpath "/private/var/db/dyld") (subpath "/Library/Apple/System"))
(allow file-read* (literal "/") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))
(allow file-read* (literal BINARY) (subpath RUNTIME))
(allow file-map-executable (subpath "/System") (subpath "/usr/lib") (literal BINARY))
(allow file-write* (subpath RUNTIME) (literal "/dev/null"))
(allow file-read-data file-write-data (subpath "/dev/fd"))
(allow process-exec (literal BINARY))
(allow process-info* (target same-sandbox))
(allow sysctl-read)
(allow signal (target same-sandbox))
(allow system-mac-syscall (require-all (mac-policy-name "Sandbox") (mac-syscall-number 67)))
(allow mach-lookup (global-name "com.apple.secinitd") (global-name "com.apple.system.opendirectoryd.libinfo"))
(allow network-outbound (remote ip "localhost:PORT"))
'''.replace('BINARY',json.dumps(str(BIN))).replace('RUNTIME',json.dumps(str(run))).replace('PORT',str(port))


def frame(event):
 return ('event: '+event['type']+'\ndata: '+json.dumps(event,ensure_ascii=False)+'\n\n').encode()


def cases():
 names=['success','unicode_boundaries','reasoning','tool','unknown_item','malformed_tool','malformed_then_valid','refusal','401','429','500','redirect','disconnect','incomplete','cancel_before_headers','cancel_during_stream','output_limit','body_limit']
 names += ['part_'+stage+'_'+kind for stage in ['added','done'] for kind in ['refusal','unknown','numeric_text']]
 names += ['message_'+stage+'_'+status for stage in ['done','final'] for status in ['incomplete','in_progress']]
 names += ['valid_in_progress_added','optional_fields_absent_or_null']
 names += ['snapshot_'+stage+'_'+bad for stage in ['created','in_progress','completed'] for bad in ['failed','incomplete','error','details','tool','refusal']]
 names += ['cumulative_body_limit','default_long_stream','harness_timeout_cleanup','final_missing_status','final_null_status']
 names += ['commentary_then_final_answer','commentary_only','unknown_message_phase','invalid_message_phase']
 names += ['metadata_headers','metadata_empty','metadata_verification','attached_safety_buffering']
 return names


def response_frames(name,original,answer):
 message={'id':'msg_fixture','type':'message','role':'assistant','content':[{'type':'output_text','text':answer}]}
 tool={'id':'tool_fixture','call_id':'call_fixture','type':'function_call','name':'exec_command','arguments':json.dumps({'cmd':'touch LUMAX_MUST_NOT_EXECUTE'})}
 item=copy.deepcopy(message)
 if name=='tool':item=copy.deepcopy(tool)
 if name=='unknown_item':item={'type':'future_tool','payload':original}
 if name=='malformed_tool':item={'type':'function_call','name':'exec_command'}
 if name=='refusal':item['content']=[{'type':'refusal','refusal':original}]
 if name=='output_limit':item['content']=[{'type':'output_text','text':'x'*(512*1024+1)}]
 created={'type':'response.created','response':{'id':'resp_fixture','status':'in_progress'}}
 added={'type':'response.output_item.added','item':copy.deepcopy(item)}
 done={'type':'response.output_item.done','item':copy.deepcopy(item)}
 final={'type':'response.completed','response':{'id':'resp_fixture','status':'completed','output':[copy.deepcopy(item)]}}
 if name in ['commentary_then_final_answer','commentary_only','unknown_message_phase','invalid_message_phase']:
  phase={'commentary_then_final_answer':'final_answer','commentary_only':'commentary','unknown_message_phase':'future_phase','invalid_message_phase':7}[name]
  for value in [added['item'],done['item'],final['response']['output'][0]]:value['phase']=phase
  if name=='commentary_then_final_answer':
   commentary=copy.deepcopy(message);commentary['phase']='commentary';commentary['content'][0]['text']=original
   final['response']['output'].insert(0,commentary)
 events=[created]
 if name=='metadata_headers':events.append({'type':'response.metadata','headers':{'openai-model':'fixture-model','x-codex-turn-state':'constructed-state'}})
 if name=='metadata_empty':events.append({'type':'response.metadata','metadata':{}})
 if name=='metadata_verification':events.append({'type':'response.metadata','metadata':{'openai_verification_recommendation':['constructed']}})
 if name=='attached_safety_buffering':created['safety_buffering']={'type':'safety_buffering','show_buffering_ui':True}
 if name=='reasoning':events.append({'type':'response.reasoning_text.delta','delta':original,'content_index':0})
 if name=='malformed_then_valid':events.append({'type':'response.output_item.done','item':{'type':'function_call','name':'exec_command'}})
 if name.startswith('part_'):
  _,stage,kind=name.split('_',2)
  part={'refusal':{'type':'refusal','refusal':original},'unknown':{'type':'future_tool','payload':original},'numeric_text':{'type':'output_text','text':7}}[kind]
  events.append({'type':'response.content_part.'+stage,'part':part})
 if name.startswith('message_'):
  _,stage,status=name.split('_',2)
  (done['item'] if stage=='done' else final['response']['output'][0])['status']=status
 if name=='valid_in_progress_added':
  added['item']['status']='in_progress';done['item']['status']='completed';final['response']['output'][0]['status']='completed'
  events.append({'type':'response.content_part.added','part':{'type':'output_text','text':''}})
  events.append({'type':'response.content_part.done','part':{'type':'output_text','text':answer}})
 if name=='optional_fields_absent_or_null':
  created['response'].pop('status',None)
  for event in [created,final]:
   event['response']['error']=None;event['response']['incomplete_details']=None
 if name=='final_missing_status':final['response'].pop('status')
 if name=='final_null_status':final['response']['status']=None
 if name.startswith('snapshot_'):
  tail=name[len('snapshot_'):]
  stage=next(stage for stage in ['created','in_progress','completed'] if tail.startswith(stage+'_'))
  bad=tail[len(stage)+1:]
  if stage=='created':snapshot=created['response']
  elif stage=='completed':snapshot=final['response']
  else:
   snapshot={'id':'resp_fixture','status':'in_progress'};events.append({'type':'response.in_progress','response':snapshot})
  if bad in ['failed','incomplete']:snapshot['status']=bad
  elif bad=='error':snapshot['error']={'code':'server_error','message':original}
  elif bad=='details':snapshot['incomplete_details']={'reason':'max_output_tokens'}
  elif bad=='tool':snapshot['output']=[copy.deepcopy(tool)]
  else:
   refusal=copy.deepcopy(message);refusal['content']=[{'type':'refusal','refusal':original}];snapshot['output']=[refusal]
 events += [added,done]
 if name=='incomplete':final['type']='response.incomplete';final['response']['status']='incomplete'
 if name!='disconnect':events.append(final)
 return events


def scenario(name,round_dir):
 run=round_dir/'runtime'/name
 for directory in ['identity','workspace','tmp']:(run/directory).mkdir(parents=True,exist_ok=False)
 token=uuid.uuid4().hex
 original='LUMAX_INPUT_'+token+'\n  A clear morning.  '
 answer='  清朗的早晨。\nLUMAX_OUTPUT_'+token+'  '
 wire=[];closed=threading.Event();finished=threading.Event();handlers_failed=[]
 class Handler(http.server.BaseHTTPRequestHandler):
  protocol_version='HTTP/1.1'
  def log_message(self,*args):pass
  def do_POST(self):
   try:
    n=int(self.headers.get('Content-Length','0'));body=json.loads(self.rfile.read(n))
    wire.append({'path':self.path,'auth_present':'Authorization' in self.headers,'shape_valid':body.get('tools')==[] and body.get('store') is False and body.get('tool_choice')=='none' and body.get('input',[{}])[0].get('content',[{}])[0].get('text')==original})
    if name in ['cancel_before_headers','harness_timeout_cleanup']:
     self.connection.settimeout(2)
     if self.connection.recv(1)==b'':closed.set()
     return
    if name in ['401','429','500','redirect']:
     status=307 if name=='redirect' else int(name);payload=json.dumps({'error':{'message':original}}).encode()
     self.send_response(status)
     if name=='redirect':self.send_header('Location','http://127.0.0.1:'+str(self.server.server_port)+'/redirected')
     self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload);return
    if name in ['cancel_during_stream','default_long_stream','cumulative_body_limit']:
     self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
     self.wfile.write(frame({'type':'response.created','response':{'id':'resp_fixture','status':'in_progress'}}));self.wfile.flush()
     if name=='cancel_during_stream':
      self.connection.settimeout(2)
      if self.connection.recv(1)==b'':closed.set()
      return
     if name=='default_long_stream':
      deadline=time.monotonic()+9
      while time.monotonic()<deadline:
       self.wfile.write(frame({'type':'response.reasoning_text.delta','delta':'fixture progress','content_index':0}));self.wfile.flush();time.sleep(.02)
      return
     # No Content-Length, individually valid frames, cumulative body exceeds 4 MiB.
     chunk=frame({'type':'response.reasoning_text.delta','delta':'x'*65536,'content_index':0})
     for _ in range(80):self.wfile.write(chunk);self.wfile.flush()
     self.connection.settimeout(2)
     if self.connection.recv(1)==b'':closed.set()
     return
    payload=b''.join(map(frame,response_frames(name,original,answer)))
    if name=='body_limit':payload=b': '+b'x'*(4*1024*1024)+b'\n\n'
    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(payload)));self.end_headers()
    if name=='unicode_boundaries':
     for i in range(0,len(payload),7):self.wfile.write(payload[i:i+7]);self.wfile.flush()
    else:self.wfile.write(payload)
   except (BrokenPipeError,ConnectionResetError):closed.set()
   except socket.timeout:pass
   except Exception as error:handlers_failed.append(type(error).__name__)
   finally:finished.set();self.close_connection=True
 server=None;proc=None;out=b'';err=b'';failure=None;returncode=None;started=time.monotonic()
 try:
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
  threading.Thread(target=server.serve_forever,daemon=True).start()
  profile=round_dir/'evidence'/(name+'.sb');profile.write_text(sandbox(run,server.server_port))
  env={'PATH':'/usr/bin:/bin','TMPDIR':str(run/'tmp'),'LANG':'en_US.UTF-8'}
  request={'endpoint':'http://127.0.0.1:'+str(server.server_port)+'/v1','text':original}
  if name.startswith('cancel_'):request['cancel_after_ms']=150
  proc=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(profile),str(BIN)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=run/'workspace',env=env)
  out,err=proc.communicate(json.dumps(request).encode(),timeout=.3 if name=='harness_timeout_cleanup' else 10)
  returncode=proc.returncode
 except Exception as error:failure=type(error).__name__
 finally:
  # Nested finally guarantees server closure even if child cleanup raises.
  try:
   if proc is not None:
    if proc.poll() is None:
     proc.terminate()
     try:out,err=proc.communicate(timeout=1)
     except subprocess.TimeoutExpired:
      proc.kill();out,err=proc.communicate(timeout=2)
    proc.wait(timeout=2);returncode=proc.returncode
  except Exception as error:
   failure='cleanup_'+type(error).__name__
   if proc is not None and proc.poll() is None:
    proc.kill();proc.wait(timeout=2)
  finally:
   elapsed=round((time.monotonic()-started)*1000)
   if server is not None:
    try:finished.wait(2);server.shutdown()
    finally:server.server_close()
 try:result=json.loads(out)
 except (ValueError,TypeError):result={'status':'invalid_process_output'}
 files=[f for f in run.rglob('*') if f.is_file()]
 leaks=[str(f.relative_to(run)) for f in files if original.encode() in f.read_bytes() or answer.encode() in f.read_bytes()]
 good=name in ['success','unicode_boundaries','reasoning','valid_in_progress_added','optional_fields_absent_or_null','commentary_then_final_answer','metadata_headers','metadata_empty']
 expected={'401':'unauthorized','429':'rate_limited','500':'unavailable','redirect':'redirect_rejected'}.get(name)
 if name.startswith('cancel_'):expected='cancelled'
 if good:expected='ok'
 if expected is None and name!='default_long_stream':expected='invalid_or_incomplete_response'
 checks={'harness_completed':failure is None and not handlers_failed,'process_exit_zero':returncode==0,'one_wire_post':len(wire)==1,'one_transport_attempt':result.get('transport_attempts')==1,'request_shape':all(x['shape_valid'] and not x['auth_present'] for x in wire),'correct_outcome':result.get('status')==expected if expected else result.get('status') in ['timeout','cancelled','invalid_or_incomplete_response'],'exact_translation':result.get('text')==answer if good else 'text' not in result,'safe_stderr':not err,'runtime_content_absent':not leaks,'no_tool_marker':not (run/'workspace/LUMAX_MUST_NOT_EXECUTE').exists(),'process_reaped':proc is not None and proc.poll() is not None}
 if name.startswith('cancel_'):checks['socket_closed_before_deadline']=closed.is_set();checks['cancel_bounded']=elapsed<2000
 if name=='default_long_stream':checks['socket_closed_by_default_deadline']=closed.is_set();checks['default_deadline_bounded']=4000<elapsed<6800
 if name=='cumulative_body_limit':checks['socket_closed_at_cumulative_limit']=closed.is_set()
 if name=='harness_timeout_cleanup':
  expected='harness_timeout'
  checks={'expected_timeout_exception':failure=='TimeoutExpired','server_received_one_post':len(wire)==1,'owned_process_reaped':proc is not None and proc.poll() is not None,'owned_process_terminated':returncode in [-15,-9],'socket_closed_after_cleanup':closed.is_set(),'no_runtime_files':not files,'stderr_empty':not err,'bounded_cleanup':elapsed<2000,'server_closed':server is not None and server.socket.fileno()==-1}
 return {'case':name,'checks':checks,'passed':all(checks.values()),'wire_posts':len(wire),'transport_attempts':result.get('transport_attempts'),'status':result.get('status'),'expected_status':expected,'elapsed_ms':elapsed,'runtime_files':[str(f.relative_to(run)) for f in files],'stderr_bytes':len(err),'exit_code':returncode,'socket_closed':closed.is_set(),'harness_failure':failure,'handler_failures':handlers_failed}


def main():
 (ROOT/'evidence').mkdir(parents=True,exist_ok=True)
 round_id=time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'-'+uuid.uuid4().hex[:8]
 round_dir=ROOT/'runs'/round_id
 (round_dir/'evidence').mkdir(parents=True,exist_ok=False)
 results=[]
 with (round_dir/'evidence/probe.log').open('w') as log:
  for name in cases():
   result=scenario(name,round_dir);results.append(result);line=json.dumps(result);log.write(line+'\n');log.flush();print(line,flush=True)
 summary={'round_id':round_id,'binary_sha256':hashlib.sha256(BIN.read_bytes()).hexdigest(),'cases':results,'passed':sum(x['passed'] for x in results),'total':len(results),'accounts_used':False,'external_model_requests':0,'auth_manager_executed':False}
 result_path=round_dir/'evidence/probe-summary.json';result_path.write_text(json.dumps(summary,indent=2)+'\n')
 (ROOT/'evidence/latest-probe-run.json').write_text(json.dumps({'round_id':round_id,'summary':str(result_path.relative_to(ROOT))},indent=2)+'\n')
 return 0 if all(x['passed'] for x in results) else 1

if __name__=='__main__':raise SystemExit(main())
