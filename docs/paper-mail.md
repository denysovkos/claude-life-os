# Paper mail and documents from chat

Mail from authorities, insurers and landlords still arrives on paper, and email is the
only input that reaches Life OS by itself. Paper gets in through one door: any file that
lands in the Life OS **Inbox** folder in Google Drive is read (with OCR for scans), filed
into the right folder and indexed the next night, with its deadlines. Everything below is
a way to put a file there.

Whichever way you use, the deadline of a letter is counted from the date printed on the
letter, never from the day you scanned it. A Bescheid scanned a week late still gets the
right Widerspruchsfrist. A letter with no legible date is flagged for you to fill in.

## 1. Scan with your phone

The Google Drive app has a document scanner that makes one clean PDF of several pages.

1. Open the Drive app, tap **+**, then **Scan**.
2. Photograph every page of the letter, then tap the check mark. Keep one letter per PDF:
   a letter split over several files is indexed as several documents.
3. On the save screen, choose the folder: Life OS → **Inbox**. Drive remembers the last
   folder, so you pick it once.

On Android, long-press the Drive icon and drag **Scan** to the home screen: two taps per
letter. On an iPhone, a scan from the Notes or Files app works too: share it, choose
Drive, and pick the Inbox folder.

Keep the paper. Authorities and notaries ask for originals, and the index records that
you have it.

## 2. A mail-scanning service

Services such as Dropscan or Caya receive your post, scan it and put the PDF in Google
Drive. Then paper reaches Life OS with nothing to do on your side.

- **If the service lets you pick the Drive folder**, pick the Life OS Inbox. Nothing else
  is needed.
- **If it writes into a folder of its own** (Dropscan saves into `Dropscan/<scanbox>/<date>`
  in your Drive), connect it to Google Drive in the service's settings, wait for the
  first scan to arrive, then say to Claude: "add my Dropscan folder as a scan inbox".
  Files there are then treated exactly like Inbox files: indexed, and moved into the
  right Life OS folder. The service's own folder is never mistaken for an area.
- **If it can only email the scans**, that works through the email intake and the bridge,
  like any attachment from an authority or insurer.

Which integrations a service offers changes. Check its integration settings rather than
this page.

## 3. From any chat or app

On a phone, the share sheet of every app (a messenger, your mail, the Files app) has
Google Drive in it. Share the PDF or photo to Drive and choose the Inbox folder. That is
the way to file a document someone sent you in WhatsApp or Telegram.

## 4. In a chat with Claude

Attach the document and say "file this" (or "ablegen", "збережи"), or just attach it.
Claude files it right away, not at night, and tells you what it is, where it went and
which deadline it starts.

- **Small files** (most PDFs that came by email) are uploaded by Claude into the right
  folder, downloaded again and compared byte for byte. A mismatch is deleted and
  reported, never kept.
- **Scans and photos** are too large to pass through a chat safely. Claude reads the copy
  you attached, tells you what it is, and gives you a link to the Inbox. Upload it there
  (or use the share sheet as in 3), say "done", and Claude indexes it on the spot.

Why not upload everything from chat: a file that passes through the AI has to be
written out byte by byte, and a PDF that was re-uploaded that way once came out silently
corrupted. Everything that moves files on its own (the bridge, the Drive app, a scanning
service) does it natively, so nothing can break on the way.
