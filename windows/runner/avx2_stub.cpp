// Stub for _Avx2WmemEnabled, referenced by firebase_firestore.lib.
// This internal MSVC runtime variable controls AVX2-optimized wmemcmp.
// Providing it as 0 disables AVX2 optimizations safely.
extern "C" int _Avx2WmemEnabled = 0;
