use std::env;
use std::path::PathBuf;

#[cfg(all(feature = "vendored", feature = "vendored-libdatachannel"))]
compile_error!(
    "Features: 'vendored' and 'vendored-libdatachannel' cannot be enabled at the same time!"
);

#[cfg(feature = "vendored")]
use once_cell::sync::OnceCell;

#[allow(dead_code)]
fn env_var_rerun(name: &str) -> Result<String, env::VarError> {
    println!("cargo:rerun-if-env-changed={}", name);
    env::var(name)
}

#[cfg(feature = "vendored")]
pub fn openssl_artifacts() -> &'static openssl_src::Artifacts {
    static INSTANCE: OnceCell<openssl_src::Artifacts> = OnceCell::new();
    INSTANCE.get_or_init(|| openssl_src::Build::new().build())
}

#[cfg(feature = "vendored")]
fn openssl_library_dir(out_dir: &str) -> PathBuf {
    let target = env::var("TARGET").expect("Cargo TARGET");
    if target.contains("-apple-") {
        let recipe = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../tools/distribuicao/construir-openssl-apple.sh");
        println!("cargo:rerun-if-changed={}", recipe.display());
        println!("cargo:rerun-if-changed={}", recipe.with_file_name("openssl-apple-sem-arquivos.patch").display());
        let status = std::process::Command::new("bash")
            .arg(recipe)
            .arg(openssl_src::source_dir())
            .arg(out_dir)
            .arg(target)
            .status()
            .expect("OpenSSL Apple recipe");
        assert!(status.success(), "OpenSSL Apple privacy-safe configuration failed");
        PathBuf::from(out_dir).join("openssl-apple/install/lib")
    } else {
        openssl_artifacts().lib_dir().to_path_buf()
    }
}

#[cfg(any(feature = "vendored", feature = "vendored-libdatachannel"))]
fn link_static_libdatachannel(out_dir: &str, profile: &str) {
    // Link static libc++
    cpp_build::Config::new()
        .include(format!("{}/lib", out_dir))
        .build("src/lib.rs");

    // Link static libjuice
    if cfg!(target_env = "msvc") {
        println!(
            "cargo:rustc-link-search=native={}/build/deps/libjuice/{}",
            out_dir, profile
        );
    } else {
        println!(
            "cargo:rustc-link-search=native={}/build/deps/libjuice",
            out_dir
        );
    }
    println!("cargo:rustc-link-lib=static=juice-static");

    // Link static usrsctplib
    if cfg!(target_env = "msvc") {
        println!(
            "cargo:rustc-link-search=native={}/build/deps/usrsctp/usrsctplib/{}",
            out_dir, profile
        );
    } else {
        println!(
            "cargo:rustc-link-search=native={}/build/deps/usrsctp/usrsctplib",
            out_dir
        );
    }
    println!("cargo:rustc-link-lib=static=usrsctp");

    if cfg!(feature = "media") {
        // Link static libsrtp
        if cfg!(target_env = "msvc") {
            println!(
                "cargo:rustc-link-search=native={}/build/deps/libsrtp/{}",
                out_dir, profile
            );
        } else {
            println!(
                "cargo:rustc-link-search=native={}/build/deps/libsrtp",
                out_dir
            );
        }
        println!("cargo:rustc-link-lib=static=srtp2");
    }

    // Link static libdatachannel
    if cfg!(target_env = "msvc") {
        println!(
            "cargo:rustc-link-search=native={}/build/{}",
            out_dir, profile
        );
    } else {
        println!("cargo:rustc-link-search=native={}/build", out_dir);
    }
    println!("cargo:rustc-link-lib=static=datachannel-static");
}

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap();

    // QUALL: the published build script only emits `rerun-if-env-changed`, which turns off
    // cargo's default "rerun when any package file changes" — so an edit to the patched C++ was
    // silently not rebuilt. Watch the libdatachannel sources we patch (see QUALL-PATCH.md).
    println!("cargo:rerun-if-changed=libdatachannel/src");
    println!("cargo:rerun-if-changed=libdatachannel/include");

    #[cfg(feature = "vendored-libdatachannel")]
    {
        let mut cmake_conf = cmake::Config::new("libdatachannel");
        cmake_conf.build_target("datachannel-static");
        cmake_conf.out_dir(&out_dir);

        cmake_conf.define("CMAKE_POLICY_VERSION_MINIMUM", "3.5");
        cmake_conf.define("NO_WEBSOCKET", "ON");
        cmake_conf.define("NO_EXAMPLES", "ON");
        // Public source snapshot omits upstream test keys/resources.
        cmake_conf.define("NO_TESTS", "ON");
        if !cfg!(feature = "media") {
            cmake_conf.define("NO_MEDIA", "ON");
        }

        if let Ok(openssl_root_dir) = env_var_rerun("OPENSSL_ROOT_DIR") {
            cmake_conf.define("OPENSSL_ROOT_DIR", openssl_root_dir);
        }
        if let Ok(openssl_libraries) = env_var_rerun("OPENSSL_LIBRARIES") {
            cmake_conf.define("OPENSSL_LIBRARIES", openssl_libraries);
        }

        cmake_conf.build();

        // Link dynamic openssl

        if cfg!(target_env = "msvc") {
            println!("cargo:rustc-link-lib=dylib=libssl");
            println!("cargo:rustc-link-lib=dylib=libcrypto");
        } else {
            println!("cargo:rustc-link-lib=dylib=ssl");
            println!("cargo:rustc-link-lib=dylib=crypto");
        }

        let profile = cmake_conf.get_profile();

        link_static_libdatachannel(&out_dir, profile);
    }

    #[cfg(feature = "vendored")]
    {
        let mut cmake_conf = cmake::Config::new("libdatachannel");
        cmake_conf.build_target("datachannel-static");
        cmake_conf.out_dir(&out_dir);

        cmake_conf.define("CMAKE_POLICY_VERSION_MINIMUM", "3.5");
        cmake_conf.define("NO_WEBSOCKET", "ON");
        cmake_conf.define("NO_EXAMPLES", "ON");
        // Public source snapshot omits upstream test keys/resources.
        cmake_conf.define("NO_TESTS", "ON");
        if !cfg!(feature = "media") {
            cmake_conf.define("NO_MEDIA", "ON");
        }

        let openssl_lib_dir = openssl_library_dir(&out_dir);
        let openssl_root_dir = openssl_lib_dir.parent().unwrap();
        cmake_conf.define("OPENSSL_ROOT_DIR", openssl_root_dir.to_path_buf());
        cmake_conf.define(
            "OPENSSL_INCLUDE_DIR",
            openssl_root_dir.to_path_buf().join("include"),
        );
        cmake_conf.define(
            "OPENSSL_CRYPTO_LIBRARY",
            openssl_root_dir.to_path_buf().join("lib/libcrypto.a"),
        );
        cmake_conf.define(
            "OPENSSL_SSL_LIBRARY",
            openssl_root_dir.to_path_buf().join("lib/libssl.a"),
        );
        cmake_conf.define("OPENSSL_USE_STATIC_LIBS", "TRUE");

        cmake_conf.build();

        let profile = cmake_conf.get_profile();

        // Link static openssl
        println!(
            "cargo:rustc-link-search=native={}",
            openssl_lib_dir.display()
        );
        if cfg!(target_env = "msvc") {
            println!("cargo:rustc-link-lib=static=libcrypto");
            println!("cargo:rustc-link-lib=static=libssl");
        } else {
            println!("cargo:rustc-link-lib=static=crypto");
            println!("cargo:rustc-link-lib=static=ssl");
        }

        link_static_libdatachannel(&out_dir, profile);
    }

    #[cfg(not(any(feature = "vendored", feature = "vendored-libdatachannel")))]
    {
        let mut cmake_conf = cmake::Config::new("libdatachannel");
        cmake_conf.out_dir(&out_dir);

        cmake_conf.define("CMAKE_POLICY_VERSION_MINIMUM", "3.5");
        cmake_conf.define("NO_WEBSOCKET", "ON");
        cmake_conf.define("NO_EXAMPLES", "ON");
        // Public source snapshot omits upstream test keys/resources.
        cmake_conf.define("NO_TESTS", "ON");
        if !cfg!(feature = "media") {
            cmake_conf.define("NO_MEDIA", "ON");
        }

        if let Ok(openssl_root_dir) = env_var_rerun("OPENSSL_ROOT_DIR") {
            cmake_conf.define("OPENSSL_ROOT_DIR", openssl_root_dir);
        }
        if let Ok(openssl_libraries) = env_var_rerun("OPENSSL_LIBRARIES") {
            cmake_conf.define("OPENSSL_LIBRARIES", openssl_libraries);
        }

        cmake_conf.build();

        // Link dynamic libdatachannel
        println!("cargo:rustc-link-search=native={}/lib", out_dir);
        println!("cargo:rustc-link-lib=dylib=datachannel");
    }

    let mut binding_builder = bindgen::Builder::default()
        .header("libdatachannel/include/rtc/rtc.h");
    // bindgen 0.59 predates Rust's Apple Silicon simulator target. Its automatic
    // translation produces arm64-apple-ios-sim, which Clang treats as a version.
    // Use the equivalent Clang target explicitly, preserving other platforms.
    if env::var("TARGET").as_deref() == Ok("aarch64-apple-ios-sim") {
        let sdk = std::process::Command::new("xcrun")
            .args(["--sdk", "iphonesimulator", "--show-sdk-path"])
            .output()
            .expect("iOS Simulator SDK path");
        assert!(sdk.status.success(), "iOS Simulator SDK unavailable");
        let sdk_path = String::from_utf8(sdk.stdout).expect("SDK path UTF-8");
        binding_builder = binding_builder
            .clang_arg("--target=arm64-apple-ios15.0-simulator")
            .clang_arg("-isysroot")
            .clang_arg(sdk_path.trim());
    }
    let bindings = binding_builder
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(out_dir);
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings");
}
