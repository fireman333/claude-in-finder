import Foundation

// App extensions are ordinary executables whose entry point hands control to the
// extension system. Xcode writes this for you; without it, it is one call.
@_silgen_name("NSExtensionMain")
func NSExtensionMain() -> Int32

exit(NSExtensionMain())
