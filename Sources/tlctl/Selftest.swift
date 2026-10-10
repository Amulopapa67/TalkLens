// SPDX-License-Identifier: MIT
// `tlctl selftest --engine apple --source ko --target zh-Hans --input F` (docs/architecture.md §7).
// STUB — translate-dev owns this file.

import Foundation

/// Returns the process exit code: 0 OK, 3 SKIP (reason printed), 1 FAIL.
func runSelftest(arguments: [String]) async -> Int32 {
    print("selftest: SKIP (not implemented yet)")
    return 3
}
