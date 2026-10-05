import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// -------------------------------------------------------------------------------------------
// ASSINATURA DE RELEASE
//
// Um APK de release **não assinado** o Android recusa instalar. Um APK de release assinado com a
// chave errada é pior: ele instala, e no dia em que a chave certa aparecer o aparelho recusa a
// atualização (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`) e a única saída é desinstalar, perdendo o
// que estiver guardado. A chave de release é a identidade do produto na loja: o Google não a
// troca depois de publicado.
//
// Por isso a chave **não** mora no repositório e **não** é gerada por script. Ela é criada uma vez
// pelo dono (o comando exato está em `apps/android/tools/empacotar-release.sh` e em
// `docs/distribuicao.md`) e chega aqui por um dos dois caminhos:
//
//   1. `apps/android/keystore.properties` — ignorado pelo Git desde esta rodada
//   2. variáveis de ambiente — o caminho de CI, onde não há arquivo em disco
//
// Sem nenhum dos dois, o `release` sai **sem** `signingConfig`: o `assembleRelease` termina e
// produz `app-release-unsigned.apk`. É o estado esperado nesta bancada, e não é defeito.
// -------------------------------------------------------------------------------------------
val propsDaChave = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

fun daChave(propriedade: String, variavel: String): String? =
    propsDaChave.getProperty(propriedade) ?: System.getenv(variavel)

val arquivoDaChave = daChave("storeFile", "QUALL_KEYSTORE")
val temChave = arquivoDaChave != null && file(arquivoDaChave).exists()

// A fonte única dos avisos acompanha cada build; não mantemos cópia versionada nos assets.
val fonteDosAvisos = rootProject.file("../../THIRD_PARTY_NOTICES.txt")
val arquivosDaLicencaPropria = listOf("LICENSE", "LICENSE-SCOPE.md", "NOTICE.txt")
    .map { rootProject.file("../../$it") }
val assetsDosAvisos = layout.buildDirectory.dir("generated/avisosDeTerceiros/assets")
val copiarAvisosDeTerceiros by tasks.registering(Sync::class) {
    from(providers.provider {
        // Avaliado antes do NO-SOURCE do Sync: arquivo faltando deve reprovar o build.
        check(fonteDosAvisos.isFile && fonteDosAvisos.length() > 0) {
            "THIRD_PARTY_NOTICES.txt ausente ou vazio na raiz do repositório"
        }
        fonteDosAvisos
    }) { into("licencas") }
    from(providers.provider {
        arquivosDaLicencaPropria.forEach { arquivo ->
            check(arquivo.isFile && arquivo.length() > 0) {
                "Licença própria ausente ou vazia: ${arquivo.name}"
            }
        }
        arquivosDaLicencaPropria
    }) { into("licencas") }
    into(assetsDosAvisos)
}
tasks.named("preBuild") { dependsOn(copiarAvisosDeTerceiros) }

android {
    namespace = "com.quall.android"
    // 36: mesmo compileSdk do A07/tablet (Android 16, API 36) — ver docs/bancada.md.
    compileSdk = 36

    // Fixado, e igual ao de `tools/android-env.sh`. O núcleo Rust é compilado por fora, com o
    // linker deste NDK, e a `libc++_shared.so` que viaja no APK vem do sysroot dele. Se o Gradle
    // escolher outro NDK para o shim JNI, o APK carrega duas metades de NDKs diferentes — e o
    // sintoma disso é o `dlopen` falhar por símbolo de C++, longe do build.
    ndkVersion = "27.2.12479018"

    defaultConfig {
        applicationId = "com.quall.android"
        // 28: o Android 9 das centrais multimídia MediaTek que se dizem "Android 10" (a AC8257 da
        // bancada, 01/10), e dos telefones antigos que servem de controle do teleprompter. A placa,
        // a DV e o DVD seguem só do 11 em diante (`capturaUsbPossivel`, em `Api28.kt`). O A10s
        // (Android 11, armv7) continua sendo o aparelho que nenhuma entrega desta frente pula.
        minSdk = 28
        targetSdk = 36
        // Vêm da linha de comando quando o `empacotar-release.sh` os passa
        // (`-PquallVersionCode=7 -PquallVersionName=0.1.0`); os valores abaixo são o padrão de
        // bancada. O número de uma release não é propriedade do código-fonte: ele muda a cada
        // publicação e não deveria produzir diff.
        versionCode = (findProperty("quallVersionCode") as String?)?.toInt() ?: 1
        versionName = (findProperty("quallVersionName") as String?) ?: "0.0.1"

        // O A10s é `armeabi-v7a` (32 bits, 1,79 GB). O A07 e o tablet são `arm64-v8a`. As duas
        // ABIs são obrigatórias: uma `.so` faltando quebra **só** no A10s, e só em execução.
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                // `libqualljni.so` é só a fachada JNI; `libquall.so` (o núcleo Rust) entra
                // pré-compilada em `src/main/jniLibs/<abi>/`, produzida por
                // `apps/android/tools/compila-nucleo.sh`.
                //
                // `max-page-size=16384`: o Android 15+ exige alinhamento de página de 16 KB em
                // arm64. Isso nunca morde o A10s, que é armv7 — morde o A07 e o tablet,
                // justamente os aparelhos que parecem os seguros
                // (`docs/divida-do-nucleo.md`, item 6).
                arguments += listOf("-DANDROID_STL=c++_shared")
                cFlags += listOf("-Wall", "-Wextra")
                cppFlags += listOf("-Wall", "-Wextra")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (temChave) {
            create("release") {
                storeFile = file(arquivoDaChave!!)
                storePassword = daChave("storePassword", "QUALL_KEYSTORE_SENHA")
                keyAlias = daChave("keyAlias", "QUALL_KEY_ALIAS")
                keyPassword = daChave("keyPassword", "QUALL_KEY_SENHA")
                // v1 desligado: o piso é o 28 e o esquema v1 (JAR) só importa abaixo do
                // Android 7. Mantê-lo ligado só acrescenta superfície — foi por v1 que passaram
                // as vulnerabilidades Janus e Master Key.
                enableV1Signing = false
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        // -------------------------------------------------------------------------------------
        // O `debug` é declarado EXPLICITAMENTE, e não porque o AGP já o cria.
        //
        // **A bancada inteira depende de o APK ser depurável.** `run-as` — que é como
        // `apps/android/tools/bancada-prefs.sh` escreve
        // `/data/data/com.quall.android/shared_prefs/quall-bancada.xml`, e como
        // `laco-de-audio.py` lê o `.wav` de dentro do `filesDir` — **só funciona em APK de
        // depuração**. Sem isso, trocar de braço de medição exigiria recompilar o APK, e aí o
        // binário medido deixa de ser o binário de produto (`core/Bancada.kt`, comentário do
        // topo).
        //
        // Escrever `isDebuggable = true` aqui não muda nada hoje; muda no dia em que alguém
        // mexer nos buildTypes sem saber disso. É uma linha que diz "isto não é padrão herdado,
        // é requisito".
        //
        // O que MUDA para a bancada com a chegada do release: `debug` e `release` têm o mesmo
        // `applicationId` e assinaturas diferentes, então **não convivem no mesmo aparelho**.
        // Instalar um por cima do outro devolve `INSTALL_FAILED_UPDATE_INCOMPATIBLE`; é preciso
        // desinstalar antes. Um `applicationIdSuffix` no debug resolveria a convivência e
        // quebraria todo `run-as com.quall.android` e todo `am force-stop` dos roteiros — troca
        // ruim.
        // -------------------------------------------------------------------------------------
        debug {
            isDebuggable = true
        }

        release {
            // R8 desligado. Ligá-lo exigiria regras para o registro de métodos nativos de
            // `quall_jni.c` contra `com.quall.android.core.QuallNative` e para o viewBinding, e
            // nenhuma delas existe. Um `minifyEnabled` sem regras produz `UnsatisfiedLinkError`
            // em execução, no aparelho, longe do build — o mesmo modo de falha que o portão de
            // símbolos do `compila-nucleo.sh` existe para evitar.
            isMinifyEnabled = false
            isDebuggable = false
            signingConfig = if (temChave) signingConfigs.getByName("release") else null
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = true
    }

    sourceSets {
        getByName("main") {
            assets.srcDir(assetsDosAvisos)
            // O FFmpeg da câmera DV (só arm64, LGPL), produzido por `tools/compila-ffmpeg-dv.sh`.
            // Fica fora de `jniLibs/` porque o `compila-nucleo.sh` apaga e recria aquela pasta.
            jniLibs.srcDirs("src/main/jniLibs", "src/main/jniLibsDv/lib")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = false
            // `libc++_shared.so` vem de dois lugares: o `compila-nucleo.sh` copia a do NDK para
            // `jniLibs` (o núcleo Rust a exige por `DT_NEEDED` — sem ela o `dlopen` falha por
            // símbolo de `basic_ostringstream`), e o CMake também produz a sua com
            // `ANDROID_STL=c++_shared`. São o mesmo arquivo do mesmo NDK; a primeira ganha.
            pickFirsts += "**/libc++_shared.so"
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")
    implementation("androidx.recyclerview:recyclerview:1.3.2")

    // CameraX: preset `camera`. `camera-lifecycle` é o motivo de MirrorService e
    // CameraCaptureService serem `LifecycleService` — `bindToLifecycle` exige um LifecycleOwner,
    // e um `Service` comum não é um.
    implementation("androidx.camera:camera-core:1.4.2")
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    // `camera-view` e `camera-video` entraram em 03/09 junto com a prévia por compositor.
    //
    // A prévia anterior desenhava `Bitmap` na CPU a ~8 quadros/s (`docs/bancada.md` §8.17), e
    // andava em trancos porque **não havia superfície sobrando**: o `Preview` tem uma só, e ela
    // era a entrada do `MediaCodec`. A troca foi inverter quem ocupa o quê — o codificador passou
    // a receber a superfície por um `VideoCapture` (daí `camera-video`), e a tela ganhou o
    // `Preview` inteiro, desenhado por uma `PreviewView` (daí `camera-view`), que em modo
    // PERFORMANCE é `SurfaceView` e portanto caminho de compositor em hardware — a mesma classe de
    // caminho que faz a prévia do iOS ser fluida.
    //
    // `camera-video` está declarado mesmo já vindo por transitividade de `camera-view`:
    // `SaidaDeVideoParaCodificador` importa `androidx.camera.video.*` direto, e depender disso
    // sem declarar é dependência não declarada.
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("androidx.camera:camera-video:1.4.2")

    // ---------------------------------------------------------------------------------------
    // TESTE JVM — o primeiro desta casca.
    //
    // Existe por uma peça só, e ela é o motivo do desenho: `receive/Fluidez.kt` é aritmética
    // pura, sem uma linha de API do Android, e por isso pode ser provada sem aparelho. Os três
    // Android desta bancada vivem ocupados, e uma medida que só se prova com um deles na mão é
    // uma medida que ninguém confere.
    //
    // **`gradle testDebugUnitTest` roda os testes; o `tools/portao.sh` NÃO.** O portão chama
    // `assembleDebug`, que não compila `src/test/`. Está dito aqui e em
    // `docs/android-para-android.md` §18 porque uma suíte que ninguém roda é pior que nenhuma:
    // ela parece prova.
    //
    // JUnit 4 e não 5: é o que a cache do Gradle desta bancada já tem (`junit:junit:4.13.2` e
    // `org.hamcrest:hamcrest-core:1.3`), e o portão roda `--offline`.
    testImplementation("junit:junit:4.13.2")
}
