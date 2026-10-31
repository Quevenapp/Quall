// O desenho do QR do convite (`docs/conexao.md` §10). Ver `qr-desenho.c`.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// O maior lado de um QR (versão 40): 177 módulos.
#define QR_LADO_MAXIMO 177

struct qr_matriz {
	int lado;
	/// `escuro[y * lado + x]`: 1 é módulo escuro.
	uint8_t escuro[QR_LADO_MAXIMO * QR_LADO_MAXIMO];
};

/// Codifica `texto` (bytes, `n` deles) em modo byte, correção **M**, na menor versão em que cabe.
/// `false` se não couber em versão nenhuma (mais de 2.331 bytes).
bool qr_codificar(const uint8_t *texto, size_t n, struct qr_matriz *saida);
