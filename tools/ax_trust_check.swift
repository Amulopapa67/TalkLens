// ax_trust_check.swift — prints whether this process (i.e. the terminal app running it) has
// Accessibility permission. Read-only. Usage: swift tools/ax_trust_check.swift
import ApplicationServices

print(AXIsProcessTrusted()
      ? "AX: trusted"
      : "AX: NOT trusted — System Settings > Privacy & Security > Accessibility: enable this terminal app")
