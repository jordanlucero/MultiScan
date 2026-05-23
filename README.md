<img width="2153" height="1083" alt="MultiScan" src="https://jordanhas.fun/portfolio-images/r4rm-MultiScanBanner-Landscape-HDR.avif" />

MultiScan provides a dedicated frontend to VisionKit that makes it easy to digitize your multi-page physical documents into text. MultiScan is built to let you review VisionKit output on a page-by-page basis, search content within pages, and feed documents into the system Accessibility Reader (⌘⎋). 

Built with Swift 6, SwiftUI (with targeted usage of AppKit and UIKit), SwiftData, and VisionKit.

<img width="3352" height="2217" alt="MultiScan running with a project open on an iMac" src="https://github.com/user-attachments/assets/40a99bfa-7a49-4193-a807-859bf1df69f4" />
<br></br>
Built with Claude Code running Claude Sonnet (4, 4.5, 4.6) and Claude Opus (4, 4.1, 4.5, 4.6, 4.7). MultiScan is appropriately sandboxed.

# Features

MultiScan projects allow you to take physical pages and perfect them into a scan that’s easy to read, analyze, and share.

* Export to RTF with optional page separation and mods
* Track your progress throughout a digitization project
* Keyword search your physical documents

## Key Limitations

MultiScan is designed for casual reading or workflows where the OCR output can be reviewed. 

* Fingers, image noise, and specks of dust/dirt might be mistaken for new or accented characters. When you're in low-light, consider using flash or night mode for MultiScan-bound images. Avoid glare.

* MultiScan doesn't have the capacity to identify illustrations or images on document pages. VisionKit will attempt to transcribe the text within artwork in a way that doesn't make sense. It's useful to include an in-line note to yourself when you export from MultiScan in case you want to add a screenshot or external scan of the artwork in an external word processor.

* This implementation of VisionKit adds line breaks at the end of each physical line of text. When appropriate, you can choose to purge line breaks from a page when editing.

# Copyright Note

MultiScan is only for use with documents you hold the copyright for, have explicit permission to digitize, or are digitzing for legally permissible use. Users should be aware that format-shifting is only legal in some jurisdictions and only allows for personal usage. Users are responsible for complying with copyright laws in their jurisdiction.
