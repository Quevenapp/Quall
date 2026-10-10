#!/usr/bin/env python3
"""Exercises the real Swift close path with an ENOSPC writer double and own fixture.
No capture, networking, mount, device storage exhaustion or production app execution.
"""
import argparse,hashlib,json,subprocess
from pathlib import Path
HARNESS=r'''
import Foundation
import CoreMedia
func naPrincipal(_ f: () -> Void) { f() }
func tr(_ s: String, _ args: CVarArg...) -> String { String(format: s, arguments: args) }
func T(_ s: String, _ args: CVarArg...) -> String { String(format: s, arguments: args) }
enum Diagnostico { static func nota(_ s: String) {} ; static func falha(_ s: String) {} }
enum GravadorLocal { static func dizerNosDois(_ s: String) {} }
enum SanitizacaoDoLog {
 static func causaExterna(_ s: String) -> String { s }
 static func erro(_ e: Error) -> String { String(describing: e) }
}
final class Entrada { func markAsFinished() {} }
final class Writer {
 enum Status: Int { case unknown, writing, completed, failed, cancelled }
 var status: Status
 let error: NSError? = NSError(domain: NSPOSIXErrorDomain, code: 28)
 var failureAtFinish=false
 var finishes=0, cancels=0
 init(_ status: Status) { self.status=status }
 func cancelWriting() { cancels+=1;status = .cancelled }
 func endSession(atSourceTime: CMTime) {}
 func finishWriting(completionHandler: () -> Void) {
  finishes+=1;status=failureAtFinish ? .failed : .completed;completionHandler()
 }
}
final class TomadaDeGravacao {
 struct Fim { let url: URL;let duracao: Double?;let quadros: UInt64;let bytes: Int64;let erro: String?;var erroNaTela: String? = nil }
 let url: URL
 let numero=1
 var fechando=false
 var writer: Writer?
 var anexados: UInt64=10
 let fimDoVideo=CMTime(seconds: 2, preferredTimescale: 600)
 let t0=CMTime.zero
 let entradaDeVideo: Entrada?=Entrada(), entradaDeSom: Entrada?=Entrada()
 var falhou: String?,falhouNaTela: String?
 init(url: URL,writer: Writer) { self.url=url;self.writer=writer }
 func preencherSilencio(ate: CMTime) {}
 func resumo() -> String { "fixture" }
 func nota(_ s: String) {}
 func falha(_ s: String) {}
 func testar(_ fim: @escaping(Fim)->Void) { CALL }
 // REAL_CLOSE
}
@main struct Testes {
 static func main() throws {
  let base=URL(fileURLWithPath: CommandLine.arguments[1]);try FileManager.default.createDirectory(at: base, withIntermediateDirectories:true)
  let bytes=Data("synthetic MP4 fixture: already written fragments".utf8)
  var checks=0
  func check(_ value:Bool,_ detail:String) { checks+=1;precondition(value,detail) }
  for mode in 0..<4 {
   let url=base.appendingPathComponent("PLATFORM-\(mode).mp4")
   try bytes.write(to:url)
   let writer=Writer(mode==0 || mode==3 ? .failed : .writing)
   writer.failureAtFinish=(mode==1)
   let tomada=TomadaDeGravacao(url:url,writer:writer)
   if mode==3 { tomada.anexados=0 }
   var result:TomadaDeGravacao.Fim?
   tomada.testar { result=$0 }
   check(result != nil,"completion must occur for each writer state")
   check(tomada.fechando,"close transition must occur")
   let r=result!
   if mode==3 {
    check(r.quadros==0,"no frames reported as recording")
    check(!FileManager.default.fileExists(atPath:url.path),"only own empty file removed")
    check(writer.cancels==1,"empty writer cancelled once")
   } else {
    check(r.quadros==10,"already written frames remain in result")
    check(try Data(contentsOf:url)==bytes,"already written file must remain for recovery")
    check(r.bytes==Int64(bytes.count),"actual size of own file preserved")
    check((r.erro != nil)==(mode != 2),"ENOSPC cannot be reported as success")
    if mode != 2 { check(r.erro!.contains("28"),"OS error survives for local diagnosis") }
   }
   check(writer.finishes==(mode==1 || mode==2 ? 1 : 0),"failed writer is never finalized again")
   try? FileManager.default.removeItem(at:url)
  }
  print("PASSOU: \(checks) verificações PLATFORM; ENOSPC ativo e no finish, sucesso e arquivo vazio")
 }
}
'''
def extract(text, needle):
 start=text.index(needle); b=text.index('{',start);p=b+1;depth=1
 while depth:
  depth+=(text[p]=='{')-(text[p]=='}');p+=1
 return text[start:p]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[1]);p.add_argument('--out',type=Path,required=True);args=p.parse_args();args.out.mkdir(parents=True,exist_ok=True)
 paths={'ios':'apps/ios/Quall/App/TomadaDeGravacao.swift','macos':'apps/macos/Sources/QuallCaptureKit/TomadaDeGravacao.swift'};results=[]
 for platform,rel in paths.items():
  source=args.source_root/rel;body=extract(source.read_text(),'    private func fechar(')
  code=HARNESS.replace('// REAL_CLOSE',body).replace('CALL','fechar(motivo: "falha de escrita", fim: fim)' if platform=='ios' else 'fechar(fim: fim)').replace('PLATFORM',platform)
  swift=args.out/(platform+'-writer.swift');swift.write_text(code);bin=args.out/(platform+'-writer')
  compile=subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-module-cache-path',str(args.out/'module-cache'),str(swift),'-o',str(bin)],capture_output=True,text=True)
  if compile.returncode:raise SystemExit(compile.stderr)
  run=subprocess.run([str(bin),str(args.out/'fixtures')],capture_output=True,text=True)
  results.append({'platform':platform,'source':str(source),'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'close_path_sha256':hashlib.sha256(body.encode()).hexdigest(),'exit_code':run.returncode,'stdout':run.stdout,'stderr':run.stderr,'writer':'double with POSIX ENOSPC','physical_disk_full':False,'real_close_path':True})
  print(run.stdout or run.stderr);(args.out/'resultados.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
  if run.returncode:raise SystemExit(run.returncode)
if __name__=='__main__':main()
