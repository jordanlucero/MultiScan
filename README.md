# MultiScan
A macOS app that runs OCR on folders containing images and lets you check its work. Perfect for turning your physical notes and documents into readable and workable text. Built with fully-native Swift, SwiftUI, SwiftData, and VisionKit frameworks. Swift 6. Requires macOS Tahoe.

![MultiScan running on an iMac with macOS Tahoe.](https://github.com/user-attachments/assets/92505022-c688-4126-98cc-3533444fda16)

**MultiScan is designed for casual reading or very particular workflows where the OCR output can be reviewed. This implementation of VisionKit might place text out of order, or make simple mistakes that you will catch while reading. I don't recommend using MultiScan for workflows that require absolute accuracy.**

Built with Claude Code and Codex running Claude 4 Opus, Claude 4 Sonnet, Claude 4.1 Opus, Claude 4.5 Sonnet, GPT-5.1-Codex-Max, and Claude 4.5 Opus. MultiScan does not have network access and is appropriately sandboxed.

# Key Limitations

MultiScan doesn't have the capacity to identify illustrations or images on document pages. VisionKit will attempt to transcribe the text within artwork in a way that doesn't make sense. It's useful to include an in-line note to yourself when you export from MultiScan in case you want to add a screenshot or external scan of the artwork in an external word processor.

This implementation of VisionKit will add line breaks at the end of each line of text that's shown on the physical document's pages. At this time, you may need to manually delete these line breaks so that text will flow more naturally in external usage.

Be mindful of the quality of your input images. Fingers, image noise, and even specks of dust and dirt on pages might be mistaken for accented characters, or new characters entirely.

# Copyright Note

MultiScan is only for use with documents you hold the copyright for, have explicit permission to digitize, or are digitzing for legally permissible personal use. Users should be aware that format-shifting is only legal in some jurisdictions and only allows for personal usage. You are responsible for complying with copyright laws in your jurisdiction.
