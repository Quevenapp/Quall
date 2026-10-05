#if COM_NUCLEO
import Foundation

/// Pré-voo do degrau 4, rodado pelo **app hospedeiro** ao abrir.
///
/// Existe por economia de toque humano. A medição que importa acontece na extension, e cada
/// transmissão começa com um toque que o iPhone 7 não automatiza. Mas quase tudo o que pode dar
/// errado antes de a extension existir dá errado igual num app comum:
///
/// * o `libquall.a` linka de verdade, e não o `libquall.dylib` de caminho do MacBook que o
///   `-lquall` escolheria;
/// * o dyld carrega 12 MB de binário com OpenSSL, usrsctp, libsrtp, libjuice e libdatachannel
///   dentro num processo **iOS 15 arm64**;
/// * os inicializadores estáticos de C++ dessas bibliotecas correm sem derrubar o processo;
/// * uma função Rust executa e devolve o valor certo — `quall_protocol_version()` tem de dar 1,
///   e `quall_generate_pin()` exercita o `getrandom` do sistema.
///
/// O que ele **não** prova, e por isso não entra no relato como se provasse: a appex é outro
/// processo, com outro teto de memória e outro provisionamento. Isto é pré-voo, não medição.
enum ProvaDoNucleo {
    static func rodar() {
        // A fronteira C é chamada direto: `Nucleo` mora no alvo da extension, e importar código
        // de um alvo no outro só para o pré-voo trocaria uma prova simples por um acoplamento.
        let antes = Diario.pegadaEmBytes
        let versao = quall_protocol_version()
        let servico = quall_service_type().map { String(cString: $0) } ?? "?"

        // Buffer fixo aqui é julgamento, não descuido: o PIN é de **seis dígitos por contrato**
        // (7 bytes com o NUL), e 16 é folga fixa. O que não pode faltar é a segunda metade da
        // comparação — `escritos <= pin.count`. Sem ela, um retorno maior que a capacidade (que é
        // como esta fronteira diz "não coube", e é **positivo**) passaria por sucesso e
        // `String(cString:)` leria um buffer zerado, imprimindo PIN vazio como se tivesse
        // sorteado. Ver `tools/confere-fronteira.py`, PERMITIDOS.
        var pin = [CChar](repeating: 0, count: 16)
        let escritos = pin.withUnsafeMutableBufferPointer { p -> Int in
            quall_generate_pin(p.baseAddress, UInt(p.count))
        }
        let sorteado = escritos > 0 && escritos <= pin.count ? String(cString: pin) : "FALHOU"
        let depois = Diario.pegadaEmBytes

        Diario.anotar("APP nucleo protocolo=\(versao) servico=\(servico) pin_sorteado=\(sorteado)"
            + " pegada_antes=\(antes) pegada_depois=\(depois)"
            + " delta=\(Int64(depois) - Int64(antes))")
    }
}
#endif
