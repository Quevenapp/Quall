// Raiz do projeto Gradle. Nada aqui além da declaração dos plugins usados pelo módulo `:app` —
// mantém a versão em um lugar só.
plugins {
    id("com.android.application") version "8.7.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}
