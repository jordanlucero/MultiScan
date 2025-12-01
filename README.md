# MultiScan
A macOS app that runs OCR on folders containing images and lets you check its work. Perfect for digitizing long physical books and documents. Built with fully-native Swift, SwiftUI, SwiftData, and VisionKit frameworks. Swift 6. Requires macOS Tahoe.

![MultiScan running on an iMac with macOS Tahoe.](https://github.com/user-attachments/assets/92505022-c688-4126-98cc-3533444fda16)

**MultiScan is designed for casual reading or very particular workflows where the OCR output can be reviewed. This implementation of VisionKit might place text out of order, or make simple mistakes that you will catch while reading. I don't recommend using MultiScan for workflows where absolute accuracy is required.**

Built with Claude Code and Codex running Claude 4 Opus, Claude 4 Sonnet, Claude 4.1 Opus, Claude 4.5 Sonnet, GPT-5.1-Codex-Max, and Claude 4.5 Opus. MultiScan does not have network access and is appropriately sandboxed.

# Key Limitations

MultiScan doesn't have the capacity to identify images contained on a document page, and will attempt to transcribe the text within them in a way that doesn't make sense. When you export the plain text, it can be useful to make note of what page numbers contain an image or graphic for simply pasting in a screenshot or external scan of the image.

This implementation of VisionKit will add line breaks at the end of each line of text that's shown on the physical document's pages. At this time, you may need to manually delete these line breaks so that text will flow naturally in some use cases, such as exporting the plain text into an EPUB document externally.

Like most simple OCR implementations, be mindful of the quality of the input images. Fingers, image noise, and specks of dust or other things on pages might be mistaken for accented characters, or new characters entirely.

MultiScan does not store the actual images used for a given project in its container. If you delete or move an image from the exact directory it existed in when the MultiScan project was generated, MultiScan will not be able to display the image linked to the page in your project.

# Known Issues

MultiScan may be highly memory-intensive when running OCR.

# Copyright Notice

MultiScan is only for use with documents you hold the copyright for, have explicit permission to digitize, or that you're digitizing for personal use only. Please note that format-shifting is only legal in some jurisdictions and only allows for personal usage. You are responsible for complying with copyright laws in your jurisdiction. This is not legal advice.
