// SPDX-License-Identifier: LGPL-2.1-or-later
// Marcador independente da prova, sem alterar o comportamento de pthreads.
__declspec(dllexport) int quall_pthread_rebuild_probe(void) { return 1000; }
