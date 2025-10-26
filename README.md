# MultiScan
A macOS app that runs OCR on folders containing images and lets you check its work. Perfect for digitizing long physical books and documents.

Built with fully-native Swift, SwiftUI, SwiftData, and VisionKit frameworks. Swift 5.9.

**Please remember to be mindful of how you use MultiScan, and to not use it in workflows where full accuracy is paramount. This implementation of VisionKit might place text out of order, or make simple mistakes that you will catch while reading.**

Built with Claude Code, using Claude 4 Opus and Sonnet.

# Key Limitations at this time

MultiScan doesn't have the capacity to identify images contained on a document page, and will attempt to transcribe the text within them in a way that doesn't make sense. When you export the plain text, it can be useful to make note of what page numbers contain an image or graphic, and just simply pasting in a screenshot of the image.

This implementation of VisionKit will add line breaks at the end of each line of text that's shown on the physical document's pages. At this time, you may need to manually delete these line breaks so that text will flow naturally in some use cases, such as exporting the plain text into an EPUB document externally.

MultiScan is highly memory-intensive when running OCR. It also does NOT properly communicate progress, with the app simply hanging during OCR processing.

Like most simple OCR implementations, be mindful of the quality of the input images. Fingers, image noise, and specks of dust or other things on pages might be mistaken for accented characters, or new characters entirely.
