//
//  HakoClashModeLayout.swift
//  ApplicationLibrary
//
//  The shape the phone's outbound-mode control takes, decided without a layout pass.
//
//  # Why the decision is a type of its own
//
//  It used to be a `private func` on `HakoHomeView`, and it answered the wrong question: it
//  asked whether the core's list was exactly `Rule`, `Global` and `Direct`, and gave every
//  other list the painted row-per-mode fallback. `clash_mode` is not a closed set - the core
//  builds the list out of the values a reader's own route and DNS rules declare - so a
//  configuration that defines three of its own modes (in Chinese, or `Proxy`/`Block`/`Auto`)
//  fell back to a taller list for no reason a reader could see. The three English words were
//  never the question. **How many modes are there, and do their names fit** is the question,
//  and the answer must not depend on which words the configuration happens to use.
//
//  It is also the half of this control that can be verified off-device: the row itself is a
//  SwiftUI view and this host has no Xcode, so
//  `scripts/dev/check_compact_mode_picker.py` compiles **this file** - not a copy of it - and
//  drives it through the lists a real configuration produces. That is why nothing under the
//  `HakoClashModeLayout` enum imports SwiftUI, reads state, or formats a string for display:
//  every decision lives here, and the view only draws what the decision says.
//
//  # The rule, and what it is calibrated against
//
//  1. Fewer than two modes is no choice at all, and the section is hidden before this type is
//     asked; more than three cannot be one row of equal thirds on a phone.
//  2. Two or three, and every name must fit its third at the size the row draws it
//     (`HakoTheme.FontRole.rowPrimary`, `title3`-weighted body) on the narrowest supported
//     phone. A name that would truncate is a name the reader cannot identify, so it declines
//     the row rather than being clipped by it.
//  3. Anything else keeps the painted list, which renders whatever it is given. **No list is
//     ever shortened** - the fallback is always the same modes the core reported.
//
//  The width budget is a conservative estimate rather than a measurement, because a static
//  audit cannot measure text. It is derived from the narrowest phone the product ships on:
//  375pt wide, minus the page's 20pt inset on each side, minus the section's 16pt padding on
//  each side = 303pt, divided by three = 101pt per third, minus the label's own 8pt padding on
//  each side = 85pt of text. At 17pt, a narrow glyph averages about 8.4pt and a full-width
//  glyph about 17pt, so 10 narrow glyphs or 5 full-width glyphs is what fits. The row also
//  carries `minimumScaleFactor(0.8)`, which absorbs the estimate's error in the direction that
//  matters.
//
//  Known boundary: the estimate assumes the default text size. At accessibility sizes the row
//  may still compress a label, which is a limitation the previous fixed-three rule had as
//  well - it is recorded here rather than fixed by measuring, because measuring is what the
//  page's charters avoid (`HakoHomeView`'s mode section comment explains why).
//

import Foundation

/// The two shapes the outbound-mode control can honestly take.
enum HakoClashModeShape: Equatable {
    /// One row of equal thirds, every mode the core reported standing on it.
    case compactRow

    /// The painted list: one row per mode, each carrying its own name and, where the product
    /// has words for the mode, the reason it exists.
    case list
}

/// The outbound-mode control's decisions, as functions of the core's list.
enum HakoClashModeLayout {
    /// The most modes one row of equal thirds can hold on a phone.
    static let maximumModesInOneRow = 3

    /// The most a label may occupy, in `widthUnits`, before the row is the wrong shape for it.
    ///
    /// Ten narrow glyphs or five full-width ones: see the header for the measurement this is
    /// derived from.
    static let maximumLabelWidthUnits = 10

    /// Which shape a list of mode names should be drawn in.
    ///
    /// Takes the *display* names - what `modeTitle` returns - because that is what the row has
    /// to fit. It never takes a business value into account: `Rule`, `规则` and `Proxy` are
    /// treated identically.
    static func shape(titles: [String]) -> HakoClashModeShape {
        guard titles.count >= 2, titles.count <= maximumModesInOneRow else {
            return .list
        }
        // Two modes the reader cannot tell apart are not three equal thirds: the row keys its
        // buttons by their name, and a repeated name is a repeated identity. The list keys its
        // rows by position and can draw them.
        guard Set(titles).count == titles.count else {
            return .list
        }
        for title in titles {
            if title.isEmpty || widthUnits(of: title) > maximumLabelWidthUnits {
                return .list
            }
        }
        return .compactRow
    }

    /// How wide `title` is estimated to be, in units of one narrow glyph.
    ///
    /// A full-width (East Asian, and the full-width punctuation beside it) scalar counts two,
    /// everything else one. Deliberately a small hand-written table rather than a Unicode
    /// property query: the answer has to be the same on every host that compiles this file,
    /// and the ranges that matter for a `clash_mode` value are these.
    static func widthUnits(of title: String) -> Int {
        title.unicodeScalars.reduce(0) { total, scalar in
            total + (isFullWidth(scalar) ? 2 : 1)
        }
    }

    private static func isFullWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100 ... 0x115F, // Hangul Jamo initial consonants
             0x2E80 ... 0x303E, // CJK radicals, Kangxi, ideographic punctuation, kana marks
             0x3041 ... 0x33FF, // kana, Hangul compatibility, CJK compatibility
             0x3400 ... 0x4DBF, // CJK unified ideographs extension A
             0x4E00 ... 0x9FFF, // CJK unified ideographs
             0xA000 ... 0xA4CF, // Yi
             0xAC00 ... 0xD7A3, // Hangul syllables
             0xF900 ... 0xFAFF, // CJK compatibility ideographs
             0xFE30 ... 0xFE4F, // CJK compatibility forms
             0xFF00 ... 0xFF60, // full-width forms
             0xFFE0 ... 0xFFE6: // full-width signs
            return true
        default:
            return false
        }
    }
}
