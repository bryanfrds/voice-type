import Carbon

// The key that types `character` with Cmd held on a keyboard layout (the current one by
// default). Cmd + V is matched by the letter, so on Dvorak-style layouts the paste has to press
// wherever V is. The Cmd layer is the one that counts: "Dvorak - QWERTY ⌘" puts V back at
// the QWERTY key while Cmd is held.
func keyCode(for character: String, layout: TISInputSource? = nil) -> CGKeyCode? {
  guard let source = layout ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
        let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
  let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
  return data.withUnsafeBytes { bytes -> CGKeyCode? in
    guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
    for code in 0..<128 {
      var deadKeys: UInt32 = 0
      var length = 0
      var chars = [UniChar](repeating: 0, count: 4)
      let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), UInt32((cmdKey >> 8) & 0xFF),
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                  &deadKeys, chars.count, &length, &chars)
      if status == noErr, String(utf16CodeUnits: chars, count: length) == character { return CGKeyCode(code) }
    }
    return nil
  }
}
