# MultiScan
MultiScan provides a dedicated frontend to VisionKit that makes it easy to digitize your multi-page physical documents into text. MultiScan is built to let you review VisionKit output on a page-by-page basis, search content within pages, and feed documents into the system Accessibility Reader (⌘⎋). 

Built with fully-native Swift, SwiftUI, SwiftData, and VisionKit frameworks. Swift 6. Requires macOS Tahoe.

![MultiScan running on an iMac with macOS Tahoe.](https://github.com/user-attachments/assets/92505022-c688-4126-98cc-3533444fda16)

Built with Claude Code running Claude Sonnet (4, 4.5) and Claude Opus (4, 4.1, 4.5). MultiScan does not have network access and is appropriately sandboxed.

# Key Limitations

MultiScan is designed for casual reading or workflows where the OCR output can be reviewed. Text might be placed out of order. Fingers, image noise, and specks of dust/dirt might be mistaken for new or accented characters. When you're in low-light, consider using flash or night mode for MultiScan-bound images. Avoid glare.

MultiScan doesn't have the capacity to identify illustrations or images on document pages. VisionKit will attempt to transcribe the text within artwork in a way that doesn't make sense. It's useful to include an in-line note to yourself when you export from MultiScan in case you want to add a screenshot or external scan of the artwork in an external word processor.

This implementation of VisionKit will add line breaks at the end of each line of text that's shown on the physical document's pages. You may need to manually delete these line breaks so that text will flow more naturally in external usage.

# Copyright Note

MultiScan is only for use with documents you hold the copyright for, have explicit permission to digitize, or are digitzing for legally permissible personal use. Users should be aware that format-shifting is only legal in some jurisdictions and only allows for personal usage. You are responsible for complying with copyright laws in your jurisdiction.
