# Quall Studio para Windows

App Rust/Win32 para Windows 11 x64, build 22000+. Captura/apresentação e áudio usam APIs
Windows; a [câmera virtual](../../integrations/camera-windows/README.md) é um componente separado.
Monitor/Tela estendida, sudoVda, crop e video wall estão fora da primeira release.

Compile localmente em Windows com Rust MSVC, ferramentas C/C++ e Windows SDK, a partir da raiz:

```powershell
cargo build --manifest-path apps/windows/Cargo.toml --locked --release --features net --bin quall-app
```

Este é um workspace Cargo próprio. Preserve seu lockfile e as features: `net` habilita o app;
`net,loja` é a variante Store. Não habilite `tela-estendida-futura` no lançamento inicial.
O portão Windows público é `tools/portao.ps1` e executa na própria máquina; não usa SSH.

Build/link MSVC, ícone/recursos, comportamento do console, câmera, MSI, assinatura e instalação
limpa precisam de verificação nativa. Metadata cruzada no macOS não comprova esses fluxos.
Este snapshot não inclui um instalador Windows aprovado; validação nativa final está pendente.
O pacote inicial não instala sudoVda. Não instale drivers ou altere confiança do sistema
apenas para conferir compilação. Veja [compilação](../../docs/compilar.md) e [limites](../../docs/limites.md).
