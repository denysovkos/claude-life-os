# Installing the Apps Script bridge

[Українською](apps-script.uk.md)

The bridge is one file, [`apps-script/Code.gs`](../apps-script/Code.gs), that runs inside
your own Google account every 15 minutes, whether Claude is running or not. It:

1. copies attachments of important mail (bills, contracts, letters from authorities)
   from Gmail into your Drive inbox folder,
2. copies them again if they vanish from Drive before they are indexed,
3. emails you if one of the Claude jobs has not run for too long,
4. rewrites the "Emergency binder" Google Doc once a day.

You do not edit the code. Everything it needs to know (which folder, which time zone,
which kinds of mail) it reads from your database. The only two things you give it are
the database address and its key.

The `life-os` skill ("set up life os") walks you through this in chat and checks the result. This page
is the same procedure, for reference. It takes about five minutes.

## Before you start

- Finish the setup steps before this one: the database and the Drive folders must exist,
  because `install` checks both.
- Be signed in to Google with the same account whose Gmail and Drive the system uses.
  If you have several Google accounts, open script.google.com in a window where only that
  one is signed in, or check the avatar in the top right corner.

## 1. Create the project and paste the code

1. Open **https://script.google.com** and click **New project** (top left).
2. Click **Untitled project** at the top and rename it to `Life OS bridge`.
3. In the editor you see a file `Code.gs` with a few lines (`function myFunction() {…}`).
   Select all of it (Ctrl+A, or Cmd+A on a Mac) and delete it.
4. Paste the whole content of `apps-script/Code.gs`. The setup skill shows it to you in
   one block with a copy button; on GitHub, open the file and use **Copy raw file**.
5. Click the **Save** icon (the floppy disk) or press Ctrl+S / Cmd+S.

The file `appsscript.json` does not need to be touched; the defaults are right.

## 2. Add the two script properties

1. In the left sidebar click the gear icon **Project Settings**.
2. Scroll down to **Script Properties** and click **Add script property**.
3. First property:
   - Property: `SUPABASE_URL`
   - Value: your project URL, for example `https://abcdefghijklmnop.supabase.co`
     (the setup skill tells you the exact value).
4. Click **Add script property** again. Second property:
   - Property: `SUPABASE_SECRET_KEY`
   - Value: the secret key. To get it: open **supabase.com** → your project →
     **Project Settings** → **API Keys** → section **Secret keys** → **Create new secret
     key**, name it `apps-script`, then click the copy icon next to it. It starts with
     `sb_secret_`.
5. Click **Save script properties**.

Two rules about the key:

- Paste it only here. Never into a chat, an email or the code. Script Properties are not
  visible to people you share the project with; the code is.
- Use the **secret** key (`sb_secret_…`), not the publishable one (`sb_publishable_…`).
  The script refuses to run with the publishable key and says so.

## 3. Run `install` and grant the permissions

1. Click the `< >` icon **Editor** in the left sidebar to go back to the code.
2. In the toolbar above the code there is a dropdown with function names. Choose
   **install**.
3. Click **Run**.
4. A window **Authorization required** appears. Click **Review permissions**.
5. Choose your Google account.
6. Google now shows **Google hasn't verified this app**. This is expected: the app is
   your own script, it was never submitted to Google for review, and nobody else runs
   it. Click **Advanced** (small link at the bottom left), then
   **Go to Life OS bridge (unsafe)**.
7. The next screen lists what the script wants to do. If it shows checkboxes, click
   **Select all**. If you leave any box unticked, the script stops later with a missing
   permission error. Then click **Allow** (or **Continue**).
8. The editor runs `install`. At the bottom, the **Execution log** opens and ends with
   `Installed. The bridge now runs every 15 minutes.`

Go back to Claude and say "done". The setup skill checks that the first run reached the
database.

### What the permissions are for

| Google asks to | Because the script |
|---|---|
| Read, compose, send and permanently delete all your email from Gmail | reads the attachments of mail the intake marked as important. The Apps Script service for Gmail only exists in this one broad form; the script never deletes or sends mail through Gmail |
| See, edit, create and delete all of your Google Drive files | creates the attachment copies in your inbox folder and checks they still exist |
| See, edit, create and delete all your Google Docs documents | writes the Emergency binder document |
| Send email as you | sends you, and only you, the alerts (`MailApp`) |
| Connect to an external service | talks to your Supabase database |
| Allow this application to run when you are not present | runs every 15 minutes on a timer |

The code is one file you can read end to end. Nothing is sent anywhere except your own
Supabase project.

## 4. Check it runs

- Left sidebar → **Triggers** (the alarm clock icon): one trigger, function `run`,
  time-based, every 15 minutes.
- Left sidebar → **Executions**: a new `run` every 15 minutes, status **Completed**.
- In chat: "life os doctor". The bridge row should be ok.

## Updating the code later

When a new version of `Code.gs` is released: open the project, replace the whole content
of `Code.gs` with the new one, save, and run `install` once more. Script properties and
permissions stay. If the new version needs a new permission, Google asks again as in
step 3.

## Common errors

| Execution log says | Fix |
|---|---|
| `Script Property SUPABASE_URL is missing` | step 2; names are case-sensitive |
| `That is the publishable key` | use the `sb_secret_…` key |
| `-> 401` | the key was deleted or belongs to another project: create a new secret key |
| `life_settings.drive_folders.inbox is empty` | the Drive folders step of setup did not finish; run setup again |
| `No item with the given ID could be found` | the script runs under another Google account than the folders, or the inbox folder was deleted |
| `You do not have permission to call …` / `Required permissions: …` | a box was unticked in step 3.7: run `install` again and tick **Select all** |

More in [troubleshooting.md](troubleshooting.md).

## Stopping it

Choose the function **uninstall** in the dropdown and click **Run**. It removes the
15-minute trigger. Nothing in Gmail, Drive or the database is deleted. To remove the
access entirely: myaccount.google.com → **Security** → **Your connections to third-party
apps & services** → **Life OS bridge** → **Delete all connections**.
