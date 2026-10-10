#!/usr/bin/env python3
"""Testa a fronteira Swift real sem compilar/executar os apps ou o núcleo.

Extrai GravacaoDoPrompter dos arquivos do produto; substitui gravador/réplica e
modelos de UI por doubles, preservando decidir() e seu callback de produção.
Saídas e module cache ficam somente no diretório indicado por --out.
"""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

HARNESS = r'''
import Foundation

struct PedidoDeGravacao { let n: UInt64; let gravar: Bool }
struct EstadoReplica { let pedidoDeGravacao: PedidoDeGravacao? }
extension UInt32 { var nome: String { self == 0 ? "OK" : "BUSY" } }
enum SessaoDoTeleprompter { static func nome(_ st: UInt32) -> String { st.nome } }
enum DiarioDoTeleprompter {
    static var linhas: [String] = []
    static func dizer(_ s: String) { linhas.append(s) }
}
final class Registro {
    static let compartilhado = Registro()
    func linha(_ s: String) { DiarioDoTeleprompter.dizer(s) }
}
final class ReplicaDoTeleprompter {
    var pedido: PedidoDeGravacao?
    var recusas: [(UInt64, String)] = []
    var definicoes: [Bool] = []
    var capacidades: [Bool] = []
    var statusDaRecusa: UInt32 = 0
    func estado() -> EstadoReplica? { EstadoReplica(pedidoDeGravacao: pedido) }
    func ligarGravacao(_ v: Bool) -> UInt32 { capacidades.append(v); return 0 }
    func definirGravando(_ v: Bool) -> UInt32 {
        definicoes.append(v)
        pedido = nil
        return 0
    }
    func recusarGravacao(n: UInt64, motivo: String) -> UInt32 {
        recusas.append((n, motivo))
        if statusDaRecusa == 0 { pedido = nil }
        return statusDaRecusa
    }
}
enum QuemPedeAGravacao { case toque, controle }
enum EstadoDaGravacao: Equatable {
    case parada, abrindo, gravando, fechando
    var gravando: Bool { self == .gravando }
    var ocupada: Bool { self != .parada }
}
final class GravadorLocal {
    var estado: EstadoDaGravacao = .parada
    var aoMudar: ((Bool) -> Void)?
    var aoTravar: ((Bool) -> Void)?
    var pedidosDeInicio = 0
    var diagnosticosLocais: [String] = []
    var conclusao: ((String?) -> Void)?
    func comecar(por quem: QuemPedeAGravacao, fim: @escaping (String?) -> Void) {
        pedidosDeInicio += 1
        estado = .abrindo
        conclusao = fim
    }
    func concluir(_ motivo: String?) {
        guard let f = conclusao else { fatalError("sem início pendente") }
        conclusao = nil
        if let motivo {
            diagnosticosLocais.append(motivo)
            estado = .parada
            f(motivo)
        } else {
            estado = .gravando
            aoMudar?(true)
            f(nil)
        }
    }
    func parar(motivo: String, fim: (() -> Void)? = nil) {
        estado = .parada
        aoMudar?(false)
        fim?()
    }
}
final class ModeloDoTeleprompter {
    let replica: ReplicaDoTeleprompter
    var aoMudarGravacao: (() -> Void)?
    init(_ r: ReplicaDoTeleprompter) { replica = r }
}
final class EscolhaDeOrientacao {
    func prenderPelaGravacao() {}
    func soltarDaGravacao() {}
}

// BRIDGE_REAL

@main struct TestesDaFronteira {
    static var verificacoes = 0
    static let mensagemEsperada = "não foi possível iniciar a gravação; veja o aviso no aparelho que grava"
    static func conferir(_ ok: @autoclosure () -> Bool, _ detalhe: String) {
        verificacoes += 1
        if !ok() {
            fputs("FALHOU: \(detalhe)\n", stderr)
            exit(1)
        }
    }
    static func ligar(_ ponte: GravacaoDoPrompter, _ r: ReplicaDoTeleprompter,
                      _ m: ModeloDoTeleprompter, _ o: EscolhaDeOrientacao) {
        // LIGAR_REAL
    }
    static func main() {
        let causas = [
            "sem espaço: sobram 23 MB (gravar pede 500 MB livres)",
            "o arquivo falhou: " + String(describing: NSError(domain: NSPOSIXErrorDomain, code: 28)),
            "sem espaço: sobram 480 MB (gravar pede 500 MB livres)",
            "sem permissão para salvar no rolo da câmera: Ajustes → Quall → Fotos",
            "não foi possível criar a pasta /Users/pessoa/Movies/Quall: erro 513",
            "a câmera não está aberta",
            "a câmera não está entregando imagem",
            "parada antes de começar",
            "encoder falhou: código 1234",
            "",
            "diagnóstico\0com NUL " + String(repeating: "🧪", count: 300)
        ]
        for (i, causa) in causas.enumerated() {
            for status: UInt32 in [0, 3] {
                DiarioDoTeleprompter.linhas = []
                let r = ReplicaDoTeleprompter()
                r.statusDaRecusa = status
                let g = GravadorLocal()
                let ponte = GravacaoDoPrompter(gravador: g)
                let m = ModeloDoTeleprompter(r)
                let o = EscolhaDeOrientacao()
                ligar(ponte, r, m, o)
                let n = UInt64(200 + i)
                r.pedido = PedidoDeGravacao(n: n, gravar: true)
                ponte.decidir()
                conferir(g.pedidosDeInicio == 1, "o pedido inicia uma vez")
                conferir(r.recusas.isEmpty, "não recusa antes da conclusão assíncrona")
                g.concluir(causa)
                conferir(r.recusas.count == 1, "uma recusa para cada falha, inclusive BUSY")
                conferir(r.recusas.first?.0 == n, "preserva número do pedido")
                conferir(r.recusas.first?.1 == mensagemEsperada,
                         "a fronteira real não deve enviar causa local, caso \(i), status \(status)")
                conferir(r.recusas[0].1.utf8.count <= 250 && !r.recusas[0].1.contains("\0"), "contrato de bytes/NUL")
                conferir(g.diagnosticosLocais == [causa], "não altera o diagnóstico recebido localmente")
                conferir(r.definicoes.isEmpty, "falha não diz que gravou")
                conferir((r.pedido == nil) == (status == 0), "preserva comportamento OK/BUSY")
                conferir(g.pedidosDeInicio == 1, "BUSY não repete o mesmo início em laço")
                let local = SanitizacaoDoLog.causaExterna(causa)
                conferir(DiarioDoTeleprompter.linhas.contains { $0.contains("recusado:") && $0.contains(local) },
                         "diário da ponte mantém a causa local conforme sanitização vigente")
            }
        }
        let r = ReplicaDoTeleprompter()
        let g = GravadorLocal()
        let ponte = GravacaoDoPrompter(gravador: g)
        let m = ModeloDoTeleprompter(r)
        let o = EscolhaDeOrientacao()
        ligar(ponte, r, m, o)
        r.pedido = PedidoDeGravacao(n: 999, gravar: true)
        ponte.decidir()
        g.concluir(nil)
        conferir(r.recusas.isEmpty, "sucesso não envia recusa")
        conferir(r.definicoes == [true], "sucesso preserva definirGravando(true)")
        conferir(r.pedido == nil, "sucesso responde ao pedido")
        print("PASSOU: \(verificacoes) verificações; \(causas.count * 2) falhas assíncronas + sucesso; BRIDGE_PLATFORM")
    }
}
'''


def extract_class(text):
    start = text.index("final class GravacaoDoPrompter {")
    pos = start + len("final class GravacaoDoPrompter {")
    depth = 1
    # O source desta classe usa chaves balanceadas inclusive nas interpolações.
    # A classe inteira é copiada: nenhuma substituição ocorre no callback real.
    while depth and pos < len(text):
        depth += (text[pos] == "{") - (text[pos] == "}")
        pos += 1
    if depth:
        raise ValueError("classe incompleta")
    return text[start:pos]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--configs", nargs="+", choices=["debug", "release"], default=["debug", "release"])
    p.add_argument("--platforms", nargs="+", choices=["ios", "macos"], default=["ios", "macos"])
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    sources = {
        "ios": "apps/ios/Quall/Teleprompter/GravacaoNaTelaComCamera.swift",
        "macos": "apps/macos/Sources/QuallApp/GravadorLocal.swift",
    }
    results = []
    for platform, relative in sources.items():
        if platform not in args.platforms:
            continue
        source = args.source_root / relative
        sanitizer_path = "apps/ios/Quall/Comum/SanitizacaoDoLog.swift" if platform == "ios" else "apps/macos/Sources/QuallApp/SanitizacaoDoLog.swift"
        sanitizer = args.source_root / sanitizer_path
        bridge = extract_class(source.read_text())
        generated = HARNESS.replace("// BRIDGE_REAL", bridge).replace("BRIDGE_PLATFORM", platform)
        call = "ponte.ligar(modelo: m, orientacao: o)" if platform == "ios" else "ponte.ligar(replica: r)"
        generated = generated.replace("// LIGAR_REAL", call)
        swift = args.out / (platform + "-fronteira.swift")
        swift.write_text(generated)
        for config in args.configs:
            binary = args.out / (platform + "-" + config)
            cmd = ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(args.out / "module-cache")]
            cmd += ["-Onone", "-D", "DEBUG"] if config == "debug" else ["-O"]
            cmd += [str(sanitizer), str(swift), "-o", str(binary)]
            compiled = subprocess.run(cmd, text=True, capture_output=True)
            if compiled.returncode:
                print(compiled.stderr, file=sys.stderr)
                raise SystemExit(compiled.returncode)
            ran = subprocess.run([str(binary)], text=True, capture_output=True)
            result = {"platform": platform, "config": config, "source": str(source),
                      "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                      "bridge_sha256": hashlib.sha256(bridge.encode()).hexdigest(),
                      "app_or_core_build": False, "network_or_capture": False,
                      "exit_code": ran.returncode, "stdout": ran.stdout, "stderr": ran.stderr}
            results.append(result)
            print(platform + " " + config + ": " + (ran.stdout or ran.stderr).strip(), flush=True)
            (args.out / "resultados.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
            if ran.returncode:
                raise SystemExit(ran.returncode)


if __name__ == "__main__":
    main()
