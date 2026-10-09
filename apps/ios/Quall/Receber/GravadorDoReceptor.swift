import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

/// Dono da gravação recebida. A interface é da principal; os bytes só cruzam a porta da tomada.
final class GravadorDoReceptor: ObservableObject {
    @Published private(set) var estado: EstadoDaGravacao = .parada
    @Published private(set) var recado = ""
    @Published private(set) var arquivosParaExportar: [URL] = []
    private let trava = NSLock()
    private var tomada: TomadaRecebida?
    private var encerrando = false
    private var formatoDoSom: (taxa: Int, canais: Int)?
    private var offsets: (video: Int64?, audio: Int64?) = (nil, nil)
    private var pedirIdr: (() -> Void)?
    private var observador: NSObjectProtocol?
    private var timer: Timer?, vez = 0, tarefa: UIBackgroundTaskIdentifier = .invalid

    init() {
        if let pasta = GravacoesPendentes.pasta() {
            arquivosParaExportar = ((try? FileManager.default.contentsOfDirectory(at: pasta,
                includingPropertiesForKeys: nil)) ?? []).filter {
                    $0.lastPathComponent.hasPrefix("Quall-recebido-") && $0.pathExtension == "mp4"
                }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        observador = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in self?.parar() }
    }
    deinit {
        if let observador { NotificationCenter.default.removeObserver(observador) }
        timer?.invalidate()
    }

    /// A nova sessão substitui a antiga só depois de a última tomada sair da porta de mídia.
    func preparar(pedirIdr: @escaping () -> Void) {
        trava.lock()
        if encerrando { tomada = nil } // A sessão nova não alimenta o arquivo da anterior.
        self.pedirIdr = pedirIdr; formatoDoSom = nil; offsets = (nil, nil); trava.unlock()
    }
    func configurarSom(taxa: Int, canais: Int) {
        trava.lock(); formatoDoSom = (taxa, canais); let t = tomada; trava.unlock()
        t?.configurarSom(taxa: taxa, canais: canais)
    }
    func relogio(video: Int64?, audio: Int64?) {
        trava.lock(); offsets = (video, audio); let t = tomada; trava.unlock()
        t?.relogio(video: video, audio: audio)
    }
    func quadro(_ bytes: UnsafeRawBufferPointer, ts: UInt64, idr: Bool) {
        trava.lock(); let t = tomada; trava.unlock(); t?.quadro(bytes, ts: ts, idr: idr)
    }
    func som(_ pcm: [Int16], taxa: Int, canais: Int, ordem: UInt16, ts: UInt64) {
        trava.lock(); let t = tomada; trava.unlock()
        t?.som(pcm, taxa: taxa, canais: canais, ordem: ordem, ts: ts)
    }
    func ruptura() { trava.lock(); let t = tomada; trava.unlock(); t?.ruptura() }

    func alternar() { estado.ocupada ? parar() : comecar() }
    private func comecar() {
        guard estado == .parada else { return }
        vez += 1; let tentativa = vez
        estado = .abrindo; recado = ""
        arquivosParaExportar = arquivosParaExportar.filter { FileManager.default.fileExists(atPath: $0.path) }
        let abrir: () -> Void = { [weak self] in
            guard let self, self.vez == tentativa, self.estado == .abrindo else { return }
            self.abrir()
        }
        if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in DispatchQueue.main.async(execute: abrir) }
        } else { abrir() }
    }
    private func abrir() {
        guard let pasta = GravacoesPendentes.pasta() else {
            estado = .parada; recado = tr("Não foi possível criar a pasta de gravações."); return
        }
        let nome = "Quall-recebido-" + UUID().uuidString
        let t = TomadaRecebida(pasta: pasta, nome: nome, aoComecar: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.estado == .abrindo else { return }
                self.estado = .gravando(desde: ProcessInfo.processInfo.systemUptime)
            }
        }, aoPedirIdr: { [weak self] in
            guard let self else { return }
            self.trava.lock(); let pedir = self.pedirIdr; self.trava.unlock(); pedir?()
        }, aoFalhar: { [weak self] _ in DispatchQueue.main.async { self?.parar() } },
        aoAbrir: GravacoesPendentes.marcarAtivo, aoDescartar: GravacoesPendentes.desmarcar)
        trava.lock(); tomada = t; encerrando = false; let formato = formatoDoSom, o = offsets, pedir = pedirIdr; trava.unlock()
        if let formato { t.configurarSom(taxa: formato.taxa, canais: formato.canais) }
        t.relogio(video: o.video, audio: o.audio)
        pedir?()
        let tentativa = vez
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.vez == tentativa, self.estado == .abrindo else { return }
            self.parar()
        }
    }
    func parar() {
        guard estado.ocupada, estado != .fechando else { return }
        vez += 1; timer?.invalidate(); timer = nil
        trava.lock(); let t = tomada; encerrando = true; trava.unlock()
        guard let t else { estado = .parada; return } // Cancelado enquanto Fotos perguntava.
        estado = .fechando
        tarefa = UIApplication.shared.beginBackgroundTask(withName: "quall.receber.gravacao.fechar") { [weak self] in
            DispatchQueue.main.async { self?.terminarTarefa() }
        }
        t.fechar { [weak self, weak t] r in DispatchQueue.main.async {
            guard let self else { return }
            self.trava.lock()
            if self.tomada === t { self.tomada = nil }
            self.encerrando = false; self.trava.unlock()
            self.salvar(r)
        } }
    }
    private func salvar(_ r: TomadaRecebida.Resultado) {
        guard !r.arquivos.isEmpty else {
            arquivosParaExportar.append(contentsOf: r.preservados)
            recado = r.preservados.isEmpty ? tr("Não foi possível concluir a gravação recebida.")
                : tr("A gravação foi interrompida. O arquivo parcial foi preservado no aparelho.")
            estado = .parada; terminarTarefa(); return
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            for url in r.arquivos { GravacoesPendentes.desmarcar(url) }
            arquivosParaExportar.append(contentsOf: r.arquivos + r.preservados)
            recado = r.erro == nil ? tr("Gravação guardada no aparelho. Use Salvar arquivo para exportar.")
                : tr("A gravação foi interrompida. Há arquivos preservados no aparelho. Use Salvar arquivo para exportar.")
            estado = .parada; terminarTarefa(); return
        }
        var faltam = r.arquivos.count, preservados = r.preservados
        for url in r.arquivos {
            GravacoesPendentes.salvarNoRolo(url, data: Date()) { [weak self] resultado in
                guard let self else { return }
                GravacoesPendentes.desmarcar(url)
                switch resultado {
                case .success: GravacoesPendentes.tirarDaPasta(url)
                case .failure: preservados.append(url)
                }
                faltam -= 1
                guard faltam == 0 else { return }
                self.arquivosParaExportar.append(contentsOf: preservados)
                self.arquivosParaExportar = self.arquivosParaExportar.filter { FileManager.default.fileExists(atPath: $0.path) }
                if r.erro != nil, !preservados.isEmpty {
                    self.recado = tr("A gravação foi interrompida. Há arquivos preservados no aparelho. Use Salvar arquivo para exportar.")
                } else if r.erro != nil { self.recado = tr("A gravação foi interrompida. Os trechos concluídos foram salvos em Fotos.") }
                else if !preservados.isEmpty { self.recado = tr("Gravação guardada no aparelho. Use Salvar arquivo para exportar.") }
                else { self.recado = tr("Gravação recebida salva em Fotos.") }
                self.estado = .parada; self.terminarTarefa()
            }
        }
    }
    private func terminarTarefa() {
        guard tarefa != .invalid else { return }
        UIApplication.shared.endBackgroundTask(tarefa); tarefa = .invalid
    }
}
